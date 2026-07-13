import Foundation
@testable import PingKit

/// Builders for synthetic wire-format packets, mirroring what the kernel
/// delivers on a Darwin ICMP datagram socket (IPv4 header included).
enum Fixtures {
    static func ipv4Datagram(
        payload: [UInt8],
        ttl: UInt8 = 64,
        protocolNumber: UInt8 = 1,
        source: (UInt8, UInt8, UInt8, UInt8) = (127, 0, 0, 1),
        optionBytes: Int = 0
    ) -> [UInt8] {
        let headerLength = 20 + optionBytes
        precondition(headerLength % 4 == 0 && headerLength <= 60)
        var header = [UInt8](repeating: 0, count: headerLength)
        header[0] = 0x40 | UInt8(headerLength / 4)
        let totalLength = headerLength + payload.count
        header[2] = UInt8(totalLength >> 8)
        header[3] = UInt8(totalLength & 0xFF)
        header[8] = ttl
        header[9] = protocolNumber
        header[12] = source.0
        header[13] = source.1
        header[14] = source.2
        header[15] = source.3
        header[16] = 127
        header[19] = 1
        return header + payload
    }

    static func echoReply(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var icmp: [UInt8] = [
            0, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
        ]
        icmp += payload
        let checksum = ICMPv4.internetChecksum(icmp)
        icmp[2] = UInt8(checksum >> 8)
        icmp[3] = UInt8(checksum & 0xFF)
        return icmp
    }

    /// Builds the reply datagram the kernel would deliver for a request that
    /// was passed to `PingSocket.send` (bare ICMP, no IP header).
    static func replyDatagram(forRequest request: [UInt8], ttl: UInt8 = 64) -> [UInt8] {
        let identifier = (UInt16(request[4]) << 8) | UInt16(request[5])
        let sequence = (UInt16(request[6]) << 8) | UInt16(request[7])
        let payload = Array(request[8...])
        return ipv4Datagram(payload: echoReply(identifier: identifier, sequence: sequence, payload: payload), ttl: ttl)
    }

    /// Builds an ICMP error datagram (e.g. type 3 or 11) embedding `request`,
    /// as sent by `source`.
    static func icmpErrorDatagram(
        type: UInt8,
        code: UInt8,
        forRequest request: [UInt8],
        source: (UInt8, UInt8, UInt8, UInt8) = (127, 0, 0, 1)
    ) -> [UInt8] {
        let embedded = ipv4Datagram(payload: request)
        var icmp: [UInt8] = [type, code, 0, 0, 0, 0, 0, 0]
        icmp += embedded
        let checksum = ICMPv4.internetChecksum(icmp)
        icmp[2] = UInt8(checksum >> 8)
        icmp[3] = UInt8(checksum & 0xFF)
        return ipv4Datagram(payload: icmp, source: source)
    }

    /// Builds an ICMP Destination Unreachable datagram embedding `request`.
    static func unreachableDatagram(forRequest request: [UInt8], code: UInt8 = 1) -> [UInt8] {
        icmpErrorDatagram(type: 3, code: code, forRequest: request)
    }

    /// Builds an ICMP Time Exceeded datagram embedding `request`, as sent by
    /// the router at `source`.
    static func timeExceededDatagram(
        forRequest request: [UInt8],
        source: (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        icmpErrorDatagram(type: 11, code: 0, forRequest: request, source: source)
    }
}

/// Test double for the socket layer. Records sends, and lets tests inject
/// arbitrary inbound datagrams, either manually or automatically per send.
final class MockPingSocket: PingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8], MonotonicTimestamp) -> Void)?
    private var sentDatagrams: [[UInt8]] = []
    private var appliedTTLs: [Int] = []
    private var currentTTL = 64
    private var isClosed = false
    private let autoReply: (@Sendable ([UInt8]) -> [UInt8]?)?
    /// TTL-aware reply strategy for traceroute tests; takes precedence over
    /// `autoReply` when set.
    private let routeReply: (@Sendable (_ datagram: [UInt8], _ ttl: Int) -> [UInt8]?)?

    init(
        autoReply: (@Sendable ([UInt8]) -> [UInt8]?)? = nil,
        routeReply: (@Sendable ([UInt8], Int) -> [UInt8]?)? = nil
    ) {
        self.autoReply = autoReply
        self.routeReply = routeReply
    }

    var sent: [[UInt8]] {
        lock.withLock { sentDatagrams }
    }

    /// TTL in effect for each send, in send order.
    var sentTTLs: [Int] {
        lock.withLock { appliedTTLs }
    }

    var closed: Bool {
        lock.withLock { isClosed }
    }

    func activate(receiveHandler: @escaping @Sendable ([UInt8], MonotonicTimestamp) -> Void) throws {
        lock.withLock { handler = receiveHandler }
    }

    func send(_ datagram: [UInt8]) throws {
        let (currentHandler, ttl) = lock.withLock {
            sentDatagrams.append(datagram)
            appliedTTLs.append(currentTTL)
            return (handler, currentTTL)
        }
        if let routeReply {
            if let reply = routeReply(datagram, ttl) {
                currentHandler?(reply, MonotonicTimestamp.now())
            }
        } else if let autoReply, let reply = autoReply(datagram) {
            currentHandler?(reply, MonotonicTimestamp.now())
        }
    }

    func setTimeToLive(_ ttl: Int) throws {
        lock.withLock { currentTTL = ttl }
    }

    func close() {
        lock.withLock { isClosed = true }
    }

    func inject(_ datagram: [UInt8]) {
        let currentHandler = lock.withLock { handler }
        currentHandler?(datagram, MonotonicTimestamp.now())
    }
}

func makePinger(configuration: PingConfiguration, socket: MockPingSocket) -> Pinger {
    Pinger(
        host: "test.invalid",
        configuration: configuration,
        socketFactory: { _ in socket },
        resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })
}

/// Holds replies until every request is pending, then delivers one burst in
/// socket callback order. This exposes ordering loss between the socket queue
/// and the actor without depending on network timing.
final class BurstReplySocket: PingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let replyCount: Int
    private var handler: (@Sendable ([UInt8], MonotonicTimestamp) -> Void)?
    private var requests: [[UInt8]] = []

    init(replyCount: Int) {
        self.replyCount = replyCount
    }

    func activate(receiveHandler: @escaping @Sendable ([UInt8], MonotonicTimestamp) -> Void) throws {
        lock.withLock { handler = receiveHandler }
    }

    func send(_ datagram: [UInt8]) throws {
        let delivery = lock.withLock { () -> ((@Sendable ([UInt8], MonotonicTimestamp) -> Void), [[UInt8]])? in
            requests.append(datagram)
            guard requests.count == replyCount, let handler else { return nil }
            return (handler, requests)
        }
        guard let (handler, requests) = delivery else { return }
        for request in requests {
            handler(Fixtures.replyDatagram(forRequest: request), MonotonicTimestamp.now())
        }
    }

    func setTimeToLive(_ ttl: Int) throws {}
    func close() {}
}
