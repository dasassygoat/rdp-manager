import Foundation

/// Finding the machine a user meant from what they typed, and finding the file the list
/// lives in. Kept apart from the command-line plumbing so it can be tested.
enum MachineLookup {
    enum Result: Equatable {
        case found(Machine)
        case notFound(query: String)
        /// More than one machine matched and none matched exactly.
        case ambiguous(query: String, names: [String])

        static func == (a: Result, b: Result) -> Bool {
            switch (a, b) {
            case let (.found(x), .found(y)): return x.id == y.id
            case let (.notFound(x), .notFound(y)): return x == y
            case let (.ambiguous(q1, n1), .ambiguous(q2, n2)): return q1 == q2 && n1 == n2
            default: return false
            }
        }
    }

    /// Matching widens only when nothing narrower hits: an exact name, then a hostname,
    /// then a name prefix, then any substring of the name. A machine called "nas" stays
    /// reachable as `nas` even when "nas-backup" exists.
    static func find(_ query: String, in machines: [Machine]) -> Result {
        let needle = query.folding()
        guard !needle.isEmpty else { return .notFound(query: query) }

        if let exact = machines.first(where: { $0.name.folding() == needle }) {
            return .found(exact)
        }
        if let host = machines.first(where: { $0.hostname.folding() == needle }) {
            return .found(host)
        }
        for candidates in [
            machines.filter { $0.name.folding().hasPrefix(needle) },
            machines.filter { $0.hostname.folding().hasPrefix(needle) },
            machines.filter { $0.name.folding().contains(needle) },
        ] {
            if candidates.count == 1 { return .found(candidates[0]) }
            if candidates.count > 1 {
                return .ambiguous(query: query, names: candidates.map(\.name).sorted())
            }
        }
        return .notFound(query: query)
    }

    /// The address to connect to: the IP the app last saw, else the hostname for ssh to
    /// resolve itself.
    static func address(of machine: Machine) -> String {
        if let ip = machine.lastIP, !ip.isEmpty { return ip }
        return machine.displayHost
    }

    /// The arguments after `ssh`, built from the machine's own username and port.
    static func sshArguments(for machine: Machine, extra: [String] = []) -> [String] {
        var args: [String] = []
        if machine.sshPort != 22 { args += ["-p", String(machine.sshPort)] }
        // The machine only has to be reachable from the jump host, not from here.
        if !machine.jumpHost.isEmpty { args += ["-J", machine.jumpHost] }
        args += extra
        let host = address(of: machine)
        args.append(machine.username.isEmpty ? host : "\(machine.username)@\(host)")
        return args
    }
}

private extension String {
    /// Case- and accent-insensitive, so `NAS` and `nas` are the same machine.
    func folding() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
