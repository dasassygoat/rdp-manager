import Foundation

/// The Mac's ARP cache, which is where a sweep gets MAC addresses from.
///
/// A MAC is only worth having because Wake-on-LAN needs one, and it is the field nobody
/// wants to type by hand. The cache only holds an entry for a host this Mac has exchanged
/// packets with recently, so a discovery pass has to probe the addresses *before* reading
/// the table — see `Discovery`.
enum ARPTable {
    /// Parses `arp -an` output into IP to MAC. Entries still being resolved appear as
    /// "(incomplete)" and are left out; the same IP can be listed once per interface, and
    /// the first complete entry wins.
    static func parse(_ output: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in output.split(separator: "\n") {
            // ? (192.168.1.1) at 6e:63:f8:38:d8:a2 on en0 ifscope [ethernet]
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: open)..<close])
            guard IPv4Subnet.parse(ip) != nil else { continue }

            let rest = line[line.index(after: close)...]
            guard let atRange = rest.range(of: " at ") else { continue }
            let field = rest[atRange.upperBound...]
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
            guard let field, let mac = normalize(String(field)) else { continue }
            if table[ip] == nil { table[ip] = mac }
        }
        return table
    }

    /// Accepts what `arp` prints — octets without a leading zero, any case — and returns the
    /// canonical form, or nil for "(incomplete)" and anything else that is not a MAC.
    static func normalize(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for part in parts {
            guard (1...2).contains(part.count), part.allSatisfy(\.isHexDigit),
                  let value = UInt8(part, radix: 16) else { return nil }
            octets.append(String(format: "%02X", value))
        }
        // A sweep can see the broadcast address in the cache; it is never a machine.
        let mac = octets.joined(separator: ":")
        return mac == "FF:FF:FF:FF:FF:FF" ? nil : mac
    }

    /// Reads the live cache. Returns an empty table rather than throwing: a sweep that
    /// cannot read MACs is still useful, it just cannot fill in Wake-on-LAN.
    static func current() async -> [String: String] {
        await Task.detached(priority: .utility) { () -> [String: String] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-an"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }
}
