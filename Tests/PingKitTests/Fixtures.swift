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

    /// Builds an ICMP Destination Unreachable datagram embedding `request`.
    static func unreachableDatagram(forRequest request: [UInt8], code: UInt8 = 1) -> [UInt8] {
        let embedded = ipv4Datagram(payload: request)
        var icmp: [UInt8] = [3, code, 0, 0, 0, 0, 0, 0]
        icmp += embedded
        let checksum = ICMPv4.internetChecksum(icmp)
        icmp[2] = UInt8(checksum >> 8)
        icmp[3] = UInt8(checksum & 0xFF)
        return ipv4Datagram(payload: icmp)
    }
}

/// Test double for the socket layer. Records sends, and lets tests inject
/// arbitrary inbound datagrams, either manually or automatically per send.
final class MockPingSocket: PingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8], ContinuousClock.Instant) -> Void)?
    private var sentDatagrams: [[UInt8]] = []
    private var isClosed = false
    private let autoReply: (@Sendable ([UInt8]) -> [UInt8]?)?

    init(autoReply: (@Sendable ([UInt8]) -> [UInt8]?)? = nil) {
        self.autoReply = autoReply
    }

    var sent: [[UInt8]] {
        lock.withLock { sentDatagrams }
    }

    var closed: Bool {
        lock.withLock { isClosed }
    }

    func activate(receiveHandler: @escaping @Sendable ([UInt8], ContinuousClock.Instant) -> Void) throws {
        lock.withLock { handler = receiveHandler }
    }

    func send(_ datagram: [UInt8]) throws {
        let currentHandler = lock.withLock {
            sentDatagrams.append(datagram)
            return handler
        }
        if let autoReply, let reply = autoReply(datagram) {
            currentHandler?(reply, ContinuousClock.now)
        }
    }

    func close() {
        lock.withLock { isClosed = true }
    }

    func inject(_ datagram: [UInt8]) {
        let currentHandler = lock.withLock { handler }
        currentHandler?(datagram, ContinuousClock.now)
    }
}

func makePinger(configuration: PingConfiguration, socket: MockPingSocket) -> Pinger {
    Pinger(
        host: "test.invalid",
        configuration: configuration,
        socketFactory: { _ in socket },
        resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })
}
