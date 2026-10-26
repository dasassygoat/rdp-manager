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
