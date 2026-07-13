import Dispatch

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Async wrapper around `getaddrinfo`. The call itself is blocking and not
/// cancellable, so it runs on a Dispatch global queue rather than a Swift
/// cooperative thread; a caller that has since been cancelled simply
/// discards the result.
enum Resolver {
    static func resolve(_ host: String, family: PingConfiguration.AddressFamily) async throws -> ResolvedEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                switch family {
                case .automatic: hints.ai_family = AF_UNSPEC
                case .ipv4: hints.ai_family = AF_INET
                case .ipv6: hints.ai_family = AF_INET6
                }
                #if canImport(Darwin)
                hints.ai_socktype = SOCK_DGRAM
                #else
                hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
                #endif

                var result: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, nil, &hints, &result)
                guard code == 0, let list = result else {
                    if let result { freeaddrinfo(result) }
                    continuation.resume(throwing: PingError.resolutionFailed(host: host, code: code))
                    return
                }
                defer { freeaddrinfo(list) }

                var node: UnsafeMutablePointer<addrinfo>? = list
                while let current = node {
                    if current.pointee.ai_family == AF_INET,
                       Int(current.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size,
                       let socketAddress = current.pointee.ai_addr {
                        let rawAddress = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            $0.pointee.sin_addr.s_addr
                        }
                        continuation.resume(returning: .ipv4(IPv4Endpoint(rawAddress: rawAddress)))
                        return
                    }
                    if current.pointee.ai_family == AF_INET6,
                       Int(current.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size,
                       let socketAddress = current.pointee.ai_addr {
                        let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                            $0.pointee
                        }
                        let bytes = withUnsafeBytes(of: address.sin6_addr) { Array($0) }
                        guard let endpoint = IPv6Endpoint(bytes: bytes, scopeID: address.sin6_scope_id) else {
                            node = current.pointee.ai_next
                            continue
                        }
                        continuation.resume(returning: .ipv6(endpoint))
                        return
                    }
                    node = current.pointee.ai_next
                }
                continuation.resume(throwing: PingError.resolutionFailed(host: host, code: EAI_NONAME))
            }
        }
    }

    static func resolveIPv4(_ host: String) async throws -> IPv4Endpoint {
        guard case .ipv4(let endpoint) = try await resolve(host, family: .ipv4) else {
            throw PingError.resolutionFailed(host: host, code: EAI_NONAME)
        }
        return endpoint
    }
}

enum ResolvedEndpoint: Hashable, Sendable {
    case ipv4(IPv4Endpoint)
    case ipv6(IPv6Endpoint)

    var address: IPAddress {
        switch self {
        case .ipv4(let endpoint): .ipv4(endpoint)
        case .ipv6(let endpoint): .ipv6(endpoint)
        }
    }
}
