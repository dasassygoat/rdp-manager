import Foundation

enum WakeOnLAN {
    enum WOLError: LocalizedError {
        case badMAC
        case socket(String)

        var errorDescription: String? {
            switch self {
            case .badMAC: return "The MAC address must be 12 hex digits, like 00:11:22:AA:BB:CC."
            case .socket(let s): return "Could not send the wake packet: \(s)"
            }
        }
    }

    static func macBytes(_ text: String) -> [UInt8]? {
        let hex = text.filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        return bytes
    }

    /// The subnet broadcast address to aim the packet at, taken from whichever interface
    /// this Mac shares with the machine.
    ///
    /// `Machine.broadcastAddress` assumes a /24 and puts .255 in the last octet, which is
    /// simply the wrong address on anything else — a /23 or a /16 broadcast is somewhere
    /// else entirely, and a packet sent to the wrong one wakes nothing. The mask is already
    /// known: `LocalInterfaces` reads it for the discovery sweep.
    ///
    /// Nil when no local interface covers the address, which means the machine is not on a
    /// network this Mac is on. The limited broadcast is still sent, and the caller may still
    /// pass its own guess.
    static func directedBroadcast(
        for ip: String?,
        interfaces: [LocalInterfaces.Interface] = LocalInterfaces.active()
    ) -> String? {
        guard let ip, let address = IPv4Subnet.parse(ip) else { return nil }
        for interface in interfaces
        where address & interface.subnet.mask == interface.subnet.networkAddress {
            return IPv4Subnet.format(interface.subnet.broadcastAddress)
        }
        return nil
    }

    /// Sends a magic packet to the limited broadcast address and, when known, the
    /// machine's subnet broadcast address.
    static func send(mac: String, directedBroadcast: String?) throws {
        guard let bytes = macBytes(mac) else { throw WOLError.badMAC }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }

        var targets = ["255.255.255.255"]
        if let directed = directedBroadcast, !targets.contains(directed) { targets.append(directed) }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw WOLError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9).bigEndian
            addr.sin_addr.s_addr = inet_addr(target)
            let sent = packet.withUnsafeBytes { buffer -> Int in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { throw WOLError.socket(String(cString: strerror(errno))) }
        }
    }
}
