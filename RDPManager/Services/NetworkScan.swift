import Foundation

/// An IPv4 subnet, used to work out which addresses a discovery sweep should probe.
///
/// Everything here is arithmetic on 32-bit addresses so it can be tested without a
/// network: the only part that touches the system is `LocalInterfaces`.
struct IPv4Subnet: Equatable, CustomStringConvertible {
    /// This Mac's own address inside the subnet.
    let address: UInt32
    let prefixLength: Int

    /// Sweeping more than this many addresses is refused. A /22 is already 1,022 hosts,
    /// which is far past a normal office LAN and well past what a polite sweep should do.
    static let maximumHosts = 1024

    init(address: UInt32, prefixLength: Int) {
        self.address = address
        self.prefixLength = min(max(prefixLength, 0), 32)
    }

    init?(address: String, netmask: String) {
        guard let a = IPv4Subnet.parse(address),
              let m = IPv4Subnet.parse(netmask),
              let prefix = IPv4Subnet.prefixLength(ofMask: m) else { return nil }
        self.init(address: a, prefixLength: prefix)
    }

    var mask: UInt32 {
        prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
    }

    var networkAddress: UInt32 { address & mask }
    var broadcastAddress: UInt32 { networkAddress | ~mask }

    /// Addresses to probe: everything in the subnet except the network address, the
    /// broadcast address and this Mac itself.
    var hostAddresses: [UInt32] {
        guard prefixLength <= 32, prefixLength >= 1 else { return [] }
        // A /31 or /32 has no usable host range in the normal sense.
        guard broadcastAddress > networkAddress + 1 else { return [] }
        let range = (networkAddress + 1)...(broadcastAddress - 1)
        guard range.count <= Self.maximumHosts else { return [] }
        return range.filter { $0 != address }
    }

    var hostCount: Int { hostAddresses.count }

    /// False when the subnet is too large to sweep, so the UI can say so rather than
    /// silently probing nothing.
    var isScannable: Bool {
        guard prefixLength >= 1, broadcastAddress > networkAddress + 1 else { return false }
        return (broadcastAddress - networkAddress - 1) <= UInt32(Self.maximumHosts)
    }

    var description: String { "\(Self.format(networkAddress))/\(prefixLength)" }

    // MARK: Address formatting

    static func parse(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text.trimmingCharacters(in: .whitespaces), &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func format(_ value: UInt32) -> String {
        "\((value >> 24) & 0xff).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
    }

    /// A netmask is only valid if its bits are contiguous from the top, so 255.255.0.255
    /// is rejected rather than quietly treated as a /24.
    static func prefixLength(ofMask mask: UInt32) -> Int? {
        let ones = mask.nonzeroBitCount
        let expected = ones == 0 ? UInt32(0) : ~UInt32(0) << (32 - ones)
        guard mask == expected else { return nil }
        return ones
    }
}

/// The IPv4 subnets this Mac is actually on.
enum LocalInterfaces {
    struct Interface: Equatable {
        var name: String
        var subnet: IPv4Subnet
    }

    /// Up, non-loopback IPv4 interfaces. Ethernet and Wi-Fi (`en*`) come first, since on a
    /// Mac with a VPN or virtualisation bridge up those are the ones a LAN scan wants.
    static func active() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, list != nil else { return [] }
        defer { freeifaddrs(list) }

        var found: [Interface] = []
        var cursor = list
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addrPointer = ifa.pointee.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = ifa.pointee.ifa_netmask else { continue }

            let address = addrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard let prefix = IPv4Subnet.prefixLength(ofMask: mask) else { continue }
            found.append(Interface(name: String(cString: ifa.pointee.ifa_name),
                                   subnet: IPv4Subnet(address: address, prefixLength: prefix)))
        }
        return found.sorted { lhs, rhs in
            let lhsPreferred = lhs.name.hasPrefix("en")
            let rhsPreferred = rhs.name.hasPrefix("en")
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.name < rhs.name
        }
    }
}
