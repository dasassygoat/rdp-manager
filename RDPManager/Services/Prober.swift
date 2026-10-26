import Foundation
import Network

/// Reachability checks: a TCP connect to the machine's service port (works even when
/// Windows blocks ping), then ICMP ping as a fallback.
enum Prober {
    struct PingResult {
        var reachable: Bool
        var latencyMs: Double?
    }

    static func tcpOpen(host: String, port: Int, timeout: TimeInterval = 2.5) async -> Bool {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let gate = OnceGate()
            let finish: (Bool) -> Void = { ok in
                guard gate.claim() else { return }
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    static func ping(_ host: String, timeoutMs: Int = 1500) async -> PingResult {
        await Task.detached(priority: .utility) { () -> PingResult in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", String(timeoutMs), "-t", "3", "-q", host]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return PingResult(reachable: false, latencyMs: nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return PingResult(reachable: false, latencyMs: nil) }
            // round-trip min/avg/max/stddev = 0.512/0.512/0.512/0.000 ms
            var latency: Double?
            let output = String(decoding: data, as: UTF8.self)
            if let eq = output.range(of: "= ") {
                let fields = output[eq.upperBound...].split(separator: "/")
                if fields.count >= 2 { latency = Double(fields[1]) }
            }
            return PingResult(reachable: true, latencyMs: latency)
        }.value
    }
}

final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
