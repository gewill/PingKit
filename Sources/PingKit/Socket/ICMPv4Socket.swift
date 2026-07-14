import Dispatch

#if canImport(Darwin)
import Darwin
import Foundation // works around a Swift 6.3 IRGen crash when this file lazily
                  // emits ObjC metadata for the DispatchSourceRead existential
#else
import Glibc
#endif

/// Unprivileged ICMP datagram socket (`SOCK_DGRAM` + `IPPROTO_ICMP`), the
/// same facility Apple's SimplePing uses. Reads are driven by a
/// `DispatchSourceRead` on a private queue; all state changes are serialized
/// on that queue.
final class ICMPv4Socket: PingSocket, @unchecked Sendable {
    private let descriptor: Int32
    private let destination: UInt32
    private let queue = DispatchQueue(label: "PingKit.ICMPv4Socket")
    private var readSource: (any DispatchSourceRead)?
    private var isClosed = false

    init(destination: IPv4Endpoint) throws {
        #if canImport(Darwin)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        #else
        let fd = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMP))
        #endif
        guard fd >= 0 else { throw PingError.socketCreationFailed(errno: errno) }
        #if canImport(Darwin)
        // Belt-and-suspenders; the read source only fires when data is ready.
        // Glibc's variadic fcntl isn't callable from Swift, so Linux skips it.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // Ask the kernel to stamp each datagram with its arrival time on the
        // mach_absolute_time clock, removing scheduler wakeup latency from
        // RTTs. Best-effort: without it we fall back to read-time stamps.
        var enable: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &enable, socklen_t(MemoryLayout<Int32>.size))
        #endif
        self.descriptor = fd
        self.destination = destination.rawAddress
    }

    deinit {
        close()
    }

    func activate(receiveHandler: @escaping @Sendable (SocketDatagram) -> Void) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.socketCreationFailed(errno: EBADF) }
            guard readSource == nil else { return }
            let fd = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                guard let (datagram, receivedAt) = Self.receiveDatagram(fd) else { return }
                receiveHandler(SocketDatagram(bytes: datagram, receivedAt: receivedAt))
            }
            // The descriptor is owned by the source once activated; closing it
            // in the cancel handler guarantees no read after close.
            source.setCancelHandler {
                Self.closeDescriptor(fd)
            }
            source.activate()
            readSource = source
        }
    }

    func send(_ datagram: [UInt8]) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.sendFailed(errno: EBADF) }
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: destination)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(descriptor, datagram, datagram.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == datagram.count else { throw PingError.sendFailed(errno: errno) }
        }
    }

    func setTimeToLive(_ ttl: Int) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.socketOptionFailed(errno: EBADF) }
            var value = Int32(ttl)
            let result = setsockopt(descriptor, Int32(IPPROTO_IP), IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
            guard result == 0 else { throw PingError.socketOptionFailed(errno: errno) }
        }
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            if let readSource {
                readSource.cancel()
            } else {
                Self.closeDescriptor(descriptor)
            }
            readSource = nil
        }
    }

    private static func closeDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    // MARK: - Receive path

    #if canImport(Darwin)
    /// Reads one datagram with `recvmsg`, extracting the kernel's
    /// `SCM_TIMESTAMP_MONOTONIC` arrival timestamp when present.
    private static func receiveDatagram(_ fd: Int32) -> ([UInt8], MonotonicTimestamp)? {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        var control = [UInt8](repeating: 0, count: 256)
        var kernelTimestamp: MonotonicTimestamp?

        let count: Int = buffer.withUnsafeMutableBytes { bufferPointer in
            control.withUnsafeMutableBytes { controlPointer in
                var vector = iovec(iov_base: bufferPointer.baseAddress, iov_len: bufferPointer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: vectorPointer,
                        msg_iovlen: 1,
                        msg_control: controlPointer.baseAddress,
                        msg_controllen: socklen_t(controlPointer.count),
                        msg_flags: 0)
                    let received = recvmsg(fd, &message, 0)
                    if received > 0 {
                        kernelTimestamp = extractMonotonicTimestamp(
                            control: controlPointer,
                            length: Int(message.msg_controllen))
                    }
                    return received
                }
            }
        }

        let receivedAt = kernelTimestamp ?? MonotonicTimestamp.now()
        guard count > 0 else { return nil }
        buffer.removeLast(buffer.count - count)
        return (buffer, receivedAt)
    }

    /// Walks the control messages for `SCM_TIMESTAMP_MONOTONIC`, whose
    /// payload is a `UInt64` in `mach_absolute_time` units.
    private static func extractMonotonicTimestamp(
        control: UnsafeMutableRawBufferPointer,
        length: Int
    ) -> MonotonicTimestamp? {
        // struct cmsghdr { socklen_t cmsg_len; int cmsg_level; int cmsg_type }
        // followed by the payload at a 4-byte-aligned offset (CMSG_DATA).
        let headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerSize <= length {
            let cmsgLength = Int(control.loadUnaligned(fromByteOffset: offset, as: socklen_t.self))
            guard cmsgLength >= headerSize, offset + cmsgLength <= length else { return nil }
            let level = control.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self)
            let type = control.loadUnaligned(fromByteOffset: offset + 8, as: Int32.self)
            if level == SOL_SOCKET, type == SCM_TIMESTAMP_MONOTONIC,
               cmsgLength >= headerSize + MemoryLayout<UInt64>.size {
                let machTicks = control.loadUnaligned(fromByteOffset: offset + headerSize, as: UInt64.self)
                return MonotonicTimestamp.fromMachAbsoluteTime(machTicks)
            }
            // Advance to the next 4-byte-aligned control message.
            offset += (cmsgLength + 3) & ~3
        }
        return nil
    }

    #else
    /// Linux: plain `recv`, stamped at read time on the same clock used for
    /// send timestamps.
    private static func receiveDatagram(_ fd: Int32) -> ([UInt8], MonotonicTimestamp)? {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let count = recv(fd, &buffer, buffer.count, 0)
        let receivedAt = MonotonicTimestamp.now()
        guard count > 0 else { return nil }
        buffer.removeLast(buffer.count - count)
        return (buffer, receivedAt)
    }
    #endif
}
