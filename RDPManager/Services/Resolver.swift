import Foundation

/// Hostname to IPv4 resolution through the system resolver, which covers DNS, the hosts
/// file, and Bonjour `.local` names.
enum Resolver {
    static func isIPv4Literal(_ text: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1
    }

    static func resolve(_ hostname: String) async -> String? {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        if isIPv4Literal(host) { return host }
        if let ip = await lookup(host) { return ip }
        if !host.contains(".") { return await lookup(host + ".local") }
        return nil
    }

    private static func lookup(_ host: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let ai = cursor {
                if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, ai.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        return String(cString: buffer)
                    }
                }
                cursor = ai.pointee.ai_next
            }
            return nil
        }.value
    }
}

extension Resolver {
    /// Reverse lookup, for naming a host a sweep found by address. Returns nil when the
    /// network has no PTR record and no Bonjour name for it, which is common.
    static func reverseLookup(_ ip: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
            guard status == 0 else { return nil }
            let name = String(cString: buffer)
            // NI_NAMEREQD means a numeric answer is an error, but be defensive anyway.
            return name.isEmpty || name == ip ? nil : name
        }.value
    }
}
