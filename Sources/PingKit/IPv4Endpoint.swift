/// An IPv4 address, stored the way the kernel hands it to us.
public struct IPv4Endpoint: Hashable, Sendable, CustomStringConvertible {
    /// The address as `in_addr.s_addr`: the four octets in network (wire)
    /// order, reinterpreted as a host `UInt32`. On the little-endian
    /// platforms Swift supports, the first octet is the lowest byte.
    public let rawAddress: UInt32

    public init(rawAddress: UInt32) {
        self.rawAddress = rawAddress
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self.rawAddress = UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16) | (UInt32(d) << 24)
    }

    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(truncatingIfNeeded: rawAddress),
            UInt8(truncatingIfNeeded: rawAddress >> 8),
            UInt8(truncatingIfNeeded: rawAddress >> 16),
            UInt8(truncatingIfNeeded: rawAddress >> 24)
        )
    }

    public var description: String {
        let o = octets
        return "\(o.0).\(o.1).\(o.2).\(o.3)"
    }
}
