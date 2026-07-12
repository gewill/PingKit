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
    static func resolveIPv4(_ host: String) async throws -> IPv4Endpoint {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
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
                        continuation.resume(returning: IPv4Endpoint(rawAddress: rawAddress))
                        return
                    }
                    node = current.pointee.ai_next
                }
                continuation.resume(throwing: PingError.resolutionFailed(host: host, code: EAI_NONAME))
            }
        }
    }
}
