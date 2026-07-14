import Dispatch

#if canImport(Darwin)
import Darwin
import Foundation
#else
import Glibc
#endif

/// Unprivileged ICMPv6 datagram socket. IPv6 source and hop-limit metadata
/// arrive through `recvmsg` rather than a prepended IP header.
final class ICMPv6Socket: PingSocket, @unchecked Sendable {
    private let descriptor: Int32
    private let destination: IPv6Endpoint
    private let queue = DispatchQueue(label: "PingKit.ICMPv6Socket")
    private var readSource: (any DispatchSourceRead)?
    private var isClosed = false

    #if canImport(Darwin)
    // RFC 3542 macros hidden from Swift by Darwin's feature flags.
    private static let receiveHopLimitOption: Int32 = 37
    private static let hopLimitControlType: Int32 = 47
    #else
    private static let receiveHopLimitOption: Int32 = 51
    private static let hopLimitControlType: Int32 = 52
    #endif

    init(destination: IPv6Endpoint) throws {
        #if canImport(Darwin)
        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        #else
        let fd = Glibc.socket(AF_INET6, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMPV6))
        #endif
        guard fd >= 0 else { throw PingError.socketCreationFailed(errno: errno) }

        #if canImport(Darwin)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var timestampEnabled: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC,
            &timestampEnabled, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var hopLimitEnabled: Int32 = 1
        let result = setsockopt(
            fd, Int32(IPPROTO_IPV6), Self.receiveHopLimitOption,
            &hopLimitEnabled, socklen_t(MemoryLayout<Int32>.size))
        guard result == 0 else {
            Self.closeDescriptor(fd)
            throw PingError.socketOptionFailed(errno: errno)
        }

        #if canImport(Darwin)
        // Only wake up for the message types ping consumes; without a filter
        // the socket also receives NDP/RA multicast traffic. Best-effort:
        // unfiltered reads are still handled (and dropped) correctly.
        // Linux ping sockets already deliver matching echo replies only and
        // don't support this raw-socket option.
        var filter = Self.makeEchoFilter()
        _ = setsockopt(
            fd, Int32(IPPROTO_ICMPV6), ICMP6_FILTER,
            &filter, socklen_t(MemoryLayout<icmp6_filter>.size))
        #endif

        self.descriptor = fd
        self.destination = destination
    }

    #if canImport(Darwin)
    /// Darwin filter semantics: a set bit passes the type; zero blocks all.
    private static func makeEchoFilter() -> icmp6_filter {
        let passTypes: [UInt8] = [
            ICMPv6.destinationUnreachableType, ICMPv6.packetTooBigType,
            ICMPv6.timeExceededType, ICMPv6.parameterProblemType, ICMPv6.echoReplyType,
        ]
        var filter = icmp6_filter()
        withUnsafeMutableBytes(of: &filter) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            for type in passTypes {
                words[Int(type) >> 5] |= UInt32(1) << (UInt32(type) & 31)
            }
        }
        return filter
    }
    #endif

    deinit { close() }

    func activate(receiveHandler: @escaping @Sendable (SocketDatagram) -> Void) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.socketCreationFailed(errno: EBADF) }
            guard readSource == nil else { return }
            let fd = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                guard let datagram = Self.receiveDatagram(fd) else { return }
                receiveHandler(datagram)
            }
            source.setCancelHandler { Self.closeDescriptor(fd) }
            source.activate()
            readSource = source
        }
    }

    func send(_ datagram: [UInt8]) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.sendFailed(errno: EBADF) }
            var address = sockaddr_in6()
            #if canImport(Darwin)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_scope_id = destination.scopeID
            withUnsafeMutableBytes(of: &address.sin6_addr) { storage in
                storage.copyBytes(from: destination.bytes)
            }
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        descriptor, datagram, datagram.count, 0,
                        socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard sent == datagram.count else { throw PingError.sendFailed(errno: errno) }
        }
    }

    func setTimeToLive(_ ttl: Int) throws {
        try queue.sync {
            guard !isClosed else { throw PingError.socketOptionFailed(errno: EBADF) }
            var value = Int32(ttl)
            let result = setsockopt(
                descriptor, Int32(IPPROTO_IPV6), IPV6_UNICAST_HOPS,
                &value, socklen_t(MemoryLayout<Int32>.size))
            guard result == 0 else { throw PingError.socketOptionFailed(errno: errno) }
        }
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            if let readSource { readSource.cancel() } else { Self.closeDescriptor(descriptor) }
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

    private static func receiveDatagram(_ fd: Int32) -> SocketDatagram? {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        var control = [UInt8](repeating: 0, count: 256)
        var sourceAddress = sockaddr_in6()
        var receivedAt: MonotonicTimestamp?
        var hopLimit: UInt8?

        let count: Int = buffer.withUnsafeMutableBytes { bufferPointer in
            control.withUnsafeMutableBytes { controlPointer in
                var vector = iovec(iov_base: bufferPointer.baseAddress, iov_len: bufferPointer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    withUnsafeMutablePointer(to: &sourceAddress) { sourcePointer in
                        var message = msghdr(
                            msg_name: sourcePointer,
                            msg_namelen: socklen_t(MemoryLayout<sockaddr_in6>.size),
                            msg_iov: vectorPointer,
                            msg_iovlen: 1,
                            msg_control: controlPointer.baseAddress,
                            msg_controllen: numericCast(controlPointer.count),
                            msg_flags: 0)
                        let received = recvmsg(fd, &message, 0)
                        if received > 0 {
                            let metadata = parseControlMessages(
                                control: controlPointer,
                                length: Int(message.msg_controllen))
                            receivedAt = metadata.timestamp
                            hopLimit = metadata.hopLimit
                        }
                        return received
                    }
                }
            }
        }

        guard count > 0 else { return nil }
        buffer.removeLast(buffer.count - count)
        let sourceBytes = withUnsafeBytes(of: sourceAddress.sin6_addr) { Array($0) }
        let source = IPv6Endpoint(bytes: sourceBytes, scopeID: sourceAddress.sin6_scope_id)
            .map(IPAddress.ipv6)
        return SocketDatagram(
            bytes: buffer,
            receivedAt: receivedAt ?? MonotonicTimestamp.now(),
            source: source,
            hopLimit: hopLimit)
    }

    private static func parseControlMessages(
        control: UnsafeMutableRawBufferPointer,
        length: Int
    ) -> (timestamp: MonotonicTimestamp?, hopLimit: UInt8?) {
        let headerSize = MemoryLayout<cmsghdr>.size
        let alignment = MemoryLayout<cmsghdr>.alignment
        var timestamp: MonotonicTimestamp?
        var hopLimit: UInt8?
        var offset = 0

        while offset + headerSize <= length {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let messageLength = Int(header.cmsg_len)
            guard messageLength >= headerSize, offset + messageLength <= length else { break }
            let dataOffset = offset + headerSize

            if header.cmsg_level == Int32(IPPROTO_IPV6),
               header.cmsg_type == hopLimitControlType,
               messageLength >= headerSize + MemoryLayout<Int32>.size {
                let value = control.loadUnaligned(fromByteOffset: dataOffset, as: Int32.self)
                if (0...255).contains(value) { hopLimit = UInt8(value) }
            }

            #if canImport(Darwin)
            if header.cmsg_level == SOL_SOCKET,
               header.cmsg_type == SCM_TIMESTAMP_MONOTONIC,
               messageLength >= headerSize + MemoryLayout<UInt64>.size {
                let ticks = control.loadUnaligned(fromByteOffset: dataOffset, as: UInt64.self)
                timestamp = MonotonicTimestamp.fromMachAbsoluteTime(ticks)
            }
            #endif

            offset += (messageLength + alignment - 1) & ~(alignment - 1)
        }
        return (timestamp, hopLimit)
    }

}
