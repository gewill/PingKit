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
        #endif
        self.descriptor = fd
        self.destination = destination.rawAddress
    }

    deinit {
        close()
    }

    func activate(receiveHandler: @escaping @Sendable ([UInt8], ContinuousClock.Instant) -> Void) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.socketCreationFailed(errno: EBADF) }
            guard readSource == nil else { return }
            let fd = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 65_535)
                let count = recv(fd, &buffer, buffer.count, 0)
                let receivedAt = ContinuousClock.now
                guard count > 0 else { return }
                buffer.removeLast(buffer.count - count)
                receiveHandler(buffer, receivedAt)
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
}
