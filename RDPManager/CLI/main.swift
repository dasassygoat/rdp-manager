import Foundation

// rdpm — start sessions from the RDP Manager machine list without opening the app.
//
// Reads the same machines.json the app writes, so an IP the app recorded a moment ago is
// the one used here. Nothing is written back.

let usage = """
usage: rdpm <command> [name] [options]

commands:
  ssh <name> [-- ssh args]   open an SSH session (replaces this process with ssh)
  ip <name>                  print the last known IP address
  host <name>                print the address that would be connected to
  show <name>                print everything known about one machine
  list [pattern]             list machines, optionally filtered
  version                    print the version
  help                       this text

options:
  --store <path>             read a specific machines.json
  --json                     machine-readable output for ip, host, show and list

exit status:
  0  fine
  1  no such machine, an ambiguous name, or the list could not be read
  2  the command line itself was wrong

<name> matches a machine name or hostname: exactly, else by prefix, else by substring.

examples:
  rdpm ssh nas
  rdpm ssh nas -- -A -L 8080:localhost:80
  ssh "$(rdpm ip shop-pc)"
  rdpm list office
"""

/// Read from the Info.plist embedded in the binary, which carries the same
/// MARKETING_VERSION as the app.
let versionText: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    switch (short, build) {
    case let (version?, build?): return "rdpm \(version) (build \(build))"
    case let (version?, nil): return "rdpm \(version)"
    default: return "rdpm (version unknown)"
    }
}()

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var storeOverride: String?
var wantsJSON = false
var passthrough: [String] = []

if let separator = arguments.firstIndex(of: "--") {
    passthrough = Array(arguments[(separator + 1)...])
    arguments = Array(arguments[..<separator])
}

var parsed: [String] = []
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--store":
        index += 1
        guard index < arguments.count else { usageError("--store needs a path") }
        storeOverride = arguments[index]
    case "--json":
        wantsJSON = true
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-v", "--version":
        print(versionText)
        exit(0)
    case let other where other.hasPrefix("-"):
        usageError("unknown option \(other)")
    case let other:
        parsed.append(other)
    }
    index += 1
}

guard let command = parsed.first else {
    print(usage)
    exit(2)
}
let name = parsed.count > 1 ? parsed[1...].joined(separator: " ") : nil

// MARK: - Commands

let storeURL = StoreLocation.resolve(explicit: storeOverride)
let machines: [Machine]
do {
    machines = try StoreLocation.load(storeURL)
} catch {
    if !FileManager.default.fileExists(atPath: storeURL.path) {
        fail("""
        no machine list at \(storeURL.path)
        Open RDP Manager and add a machine, or point at the file with --store or \
        \(StoreLocation.environmentKey).
        """)
    }
    fail("could not read \(storeURL.path): \(error.localizedDescription)")
}

switch command {
case "help":
    print(usage)

case "version":
    print(versionText)

case "list":
    let shown = listed(matching: name, in: machines)
    if wantsJSON {
        printJSON(shown.map(summary))
    } else if shown.isEmpty {
        complain("no machines matched")
        exit(1)
    } else {
        printTable(shown)
    }

case "ssh":
    let machine = resolve(name)
    let arguments = MachineLookup.sshArguments(for: machine, extra: passthrough)
    // Hand the terminal over to ssh: it owns the tty, the signals and the exit status.
    let argv: [String] = ["ssh"] + arguments
    var pointers = argv.map { strdup($0) } + [nil]
    execvp("ssh", &pointers)
    fail("could not start ssh: \(String(cString: strerror(errno)))")

case "ip":
    let machine = resolve(name)
    guard let ip = machine.lastIP, !ip.isEmpty else {
        fail("no IP recorded for \(machine.name) yet; it resolves as \(machine.displayHost)")
    }
    wantsJSON ? printJSON(["name": machine.name, "ip": ip]) : print(ip)

case "host":
    let machine = resolve(name)
    let host = MachineLookup.address(of: machine)
    wantsJSON ? printJSON(["name": machine.name, "host": host]) : print(host)

case "show":
    let machine = resolve(name)
    if wantsJSON {
        printJSON(summary(machine))
    } else {
        printDetails(machine)
    }

default:
    usageError("unknown command \(command)")
}

// MARK: - Helpers

func resolve(_ name: String?) -> Machine {
    guard let name, !name.isEmpty else { usageError("which machine?") }
    switch MachineLookup.find(name, in: machines) {
    case .found(let machine):
        return machine
    case .notFound:
        let known = machines.map(\.name).sorted().joined(separator: ", ")
        fail("no machine matching \"\(name)\"" + (known.isEmpty ? "" : "\nknown: \(known)"))
    case .ambiguous(_, let names):
        fail("\"\(name)\" matches several machines: \(names.joined(separator: ", "))")
    }
}

func listed(matching pattern: String?, in machines: [Machine]) -> [Machine] {
    let sorted = machines.sorted {
        ($0.group, $0.name.lowercased()) < ($1.group, $1.name.lowercased())
    }
    guard let pattern, !pattern.isEmpty else { return sorted }
    let needle = pattern.lowercased()
    return sorted.filter {
        [$0.name, $0.hostname, $0.group, $0.tags.joined(separator: " ")]
            .contains { $0.lowercased().contains(needle) }
    }
}

func printTable(_ machines: [Machine]) {
    let rows = machines.map {
        [$0.name, $0.group, MachineLookup.address(of: $0), $0.primary.label.lowercased()]
    }
    let headers = ["NAME", "GROUP", "ADDRESS", "VIA"]
    let widths = (0..<headers.count).map { column in
        max(headers[column].count, rows.map { $0[column].count }.max() ?? 0)
    }
    func line(_ cells: [String]) -> String {
        zip(cells, widths)
            .map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }
    print(line(headers))
    rows.forEach { print(line($0)) }
}

func printDetails(_ machine: Machine) {
    var lines = [
        ("name", machine.name),
        ("hostname", machine.displayHost),
        ("address", MachineLookup.address(of: machine)),
        ("kind", machine.kind.label),
        ("connect with", machine.primary.label),
        ("ssh", "port \(machine.sshPort)" + (machine.username.isEmpty ? "" : ", user \(machine.username)")),
    ]
    if !machine.group.isEmpty { lines.append(("group", machine.group)) }
    if !machine.tags.isEmpty { lines.append(("tags", machine.tagsText)) }
    if !machine.macAddress.isEmpty { lines.append(("mac", machine.macAddress)) }
    if let seen = machine.lastSeen {
        lines.append(("last seen", seen.formatted(date: .abbreviated, time: .shortened)))
    }
    if !machine.notes.isEmpty { lines.append(("notes", machine.notes)) }
    let width = lines.map(\.0.count).max() ?? 0
    for (label, value) in lines {
        print(label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
    }
    if !machine.ipHistory.isEmpty {
        print("\nip history (newest last)")
        for record in machine.ipHistory.suffix(10) {
            print("  \(record.ip)  \(record.seenAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

func summary(_ machine: Machine) -> [String: String] {
    [
        "name": machine.name,
        "hostname": machine.displayHost,
        "address": MachineLookup.address(of: machine),
        "ip": machine.lastIP ?? "",
        "group": machine.group,
        "username": machine.username,
        "sshPort": String(machine.sshPort),
        "primary": machine.primary.rawValue,
    ]
}

func printJSON(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value) || value is [Any],
          let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        fail("could not encode output as JSON")
    }
    print(text)
}

/// Something went wrong at runtime: an unknown machine, an ambiguous name, an unreadable
/// list.
func fail(_ message: String) -> Never {
    complain(message)
    exit(1)
}

/// The command line itself was wrong, which scripts distinguish from a lookup that missed.
func usageError(_ message: String) -> Never {
    complain(message + "\n\n" + usage)
    exit(2)
}

func complain(_ message: String) {
    FileHandle.standardError.write(Data(("rdpm: " + message + "\n").utf8))
}
