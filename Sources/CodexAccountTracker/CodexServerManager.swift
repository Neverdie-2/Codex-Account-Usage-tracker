import Foundation

final class CodexServerManager {
    private var process: Process?
    private var outputPipe: Pipe?
    private var startedAt: Date?
    private(set) var endpoint: URL?

    var onOutput: ((String) -> Void)?
    /// Fired when the managed server terminates. The second argument is how many
    /// seconds the process stayed alive — a near-zero value means it crashed on
    /// launch (e.g. a broken `codex` install), which the caller uses to back off.
    var onTermination: ((URL?, TimeInterval) -> Void)?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func startIfNeeded(endpoint: URL) {
        clearExitedProcessIfNeeded()
        guard process == nil else { return }
        guard let codexURL = findCodexExecutable() else {
            onOutput?("codex executable was not found in /usr/local/bin, /opt/homebrew/bin, or PATH.")
            return
        }

        let process = Process()
        process.executableURL = codexURL
        process.arguments = [
            "app-server",
            "--listen",
            endpoint.absoluteString
        ]
        process.environment = launchEnvironment()

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, self.process === process else { return }
                let endpoint = self.endpoint
                let uptime = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.clearProcessState()
                self.onTermination?(endpoint, uptime)
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.onOutput?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = output
            self.endpoint = endpoint
            self.startedAt = Date()
        } catch {
            onOutput?("Failed to start codex app-server: \(error.localizedDescription)")
        }
    }

    func restart(endpoint: URL) async {
        stop()
        terminateExistingTrackerServer(endpoint: endpoint)
        try? await Task.sleep(nanoseconds: 350_000_000)
        startIfNeeded(endpoint: endpoint)
    }

    func stop() {
        process?.terminationHandler = nil
        clearProcessState(terminate: true)
    }

    private func clearExitedProcessIfNeeded() {
        guard let process, !process.isRunning else { return }
        process.terminationHandler = nil
        clearProcessState()
    }

    private func clearProcessState(terminate: Bool = false) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if terminate {
            terminateChildren(of: process)
            process?.terminate()
        }
        process = nil
        outputPipe = nil
        endpoint = nil
        startedAt = nil
    }

    private func terminateChildren(of process: Process?) {
        guard let process else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        do {
            try pkill.run()
            pkill.waitUntilExit()
        } catch {
            return
        }
    }

    private func terminateExistingTrackerServer(endpoint: URL) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = [
            "-TERM",
            "-f",
            "app-server --listen \(endpoint.absoluteString)"
        ]
        do {
            try pkill.run()
            pkill.waitUntilExit()
        } catch {
            return
        }
    }

    private func findCodexExecutable() -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = environmentPath
            .split(separator: ":")
            .map { String($0) }
            + [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/opt/local/bin"
            ]

        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let pathParts = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = (pathParts + [currentPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        return environment
    }
}
