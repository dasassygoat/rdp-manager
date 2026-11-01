import Foundation

/// The Mac's ARP cache, which is where a sweep gets MAC addresses from.
///
/// A MAC is only worth having because Wake-on-LAN needs one, and it is the field nobody
/// wants to type by hand. The cache only holds an entry for a host this Mac has exchanged
/// packets with recently, so a discovery pass has to probe the addresses *before* reading
/// the table — see `Discovery`.
///
/// The table is read straight from the routing socket. Shelling out to `arp -an` looks
/// simpler and is what a person would type, but a subprocess is handed an empty table:
/// `arp` exits 0 having printed nothing, with no error to report, so every MAC silently
/// came back missing.
enum ARPTable {
    /// Reads the live cache. Returns an empty table rather than throwing: a sweep that
    /// cannot read MACs is still useful, it just cannot fill in Wake-on-LAN.
    static func current() -> [String: String] {
        // RTF_LLINFO, the flag for the link-layer entries that make up the ARP cache. It
        // is not in the Swift overlay, so the value from <net/route.h> is spelled out.
        let rtfLLInfo: Int32 = 0x400
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, rtfLLInfo]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: needed)
        // The table can grow between the sizing call and this one, which fails with ENOMEM
        // rather than truncating; a sweep is not worth retrying for.
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return [:] }
        return macs(inRoutingMessages: Array(buffer.prefix(needed)))
    }

    /// Pulls IP to MAC out of a block of routing messages, each one a `rt_msghdr` followed
    /// by the addresses its `rtm_addrs` mask names. Entries still being resolved carry no
    /// link address and are left out; the same IP can appear once per interface, and the
    /// first complete entry wins.
    static func macs(inRoutingMessages buffer: [UInt8]) -> [String: String] {
        var table: [String: String] = [:]
        var offset = 0
        let headerSize = MemoryLayout<rt_msghdr>.size
        while offset + headerSize <= buffer.count {
            let header = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
            }
            let length = Int(header.rtm_msglen)
            // A zero or negative length would spin here forever on a malformed table.
            guard length > headerSize, offset + length <= buffer.count else { break }
            defer { offset += length }

            // Destination then gateway, the order the mask lists them in.
            guard header.rtm_addrs & RTA_DST != 0, header.rtm_addrs & RTA_GATEWAY != 0 else {
                continue
            }
            let end = offset + length
            let sinOffset = offset + headerSize
            guard let ip = ipv4(in: buffer, at: sinOffset, end: end) else { continue }
            let sdlOffset = sinOffset + socketAddressStride(in: buffer, at: sinOffset)
            guard let mac = linkAddress(in: buffer, at: sdlOffset, end: end) else { continue }
            if table[ip] == nil { table[ip] = mac }
        }
        return table
    }

    /// Addresses in a routing message are padded out to a multiple of four bytes, and a
    /// zero-length one still takes four.
    private static func socketAddressStride(in buffer: [UInt8], at offset: Int) -> Int {
        guard offset < buffer.count else { return 4 }
        let length = Int(buffer[offset])
        return length == 0 ? 4 : 1 + ((length - 1) | 3)
    }

    /// `sockaddr_in`: length, family, port, then the four address bytes.
    private static func ipv4(in buffer: [UInt8], at offset: Int, end: Int) -> String? {
        guard offset + 8 <= end, buffer[offset + 1] == UInt8(AF_INET) else { return nil }
        let address = buffer[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        return IPv4Subnet.format(address)
    }

    /// `sockaddr_dl`: eight fixed bytes, then the interface name followed by the hardware
    /// address, whose lengths the header gives.
    private static func linkAddress(in buffer: [UInt8], at offset: Int, end: Int) -> String? {
        guard offset + 8 <= end, buffer[offset + 1] == UInt8(AF_LINK) else { return nil }
        let nameLength = Int(buffer[offset + 5])
        let addressLength = Int(buffer[offset + 6])
        guard addressLength == 6 else { return nil }
        let start = offset + 8 + nameLength
        guard start + addressLength <= end else { return nil }
        return normalize(buffer[start..<(start + addressLength)]
            .map { String(format: "%02x", $0) }
            .joined(separator: ":"))
    }

    /// Takes the usual written forms — octets without a leading zero, any case — and
    /// returns the canonical one, or nil for anything that is not a MAC.
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
}
