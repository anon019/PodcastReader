import Foundation

enum PipelineError: Error, LocalizedError {
    case resources(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .resources(let message), .failed(let message): message
        }
    }
}

enum PipelineRunner {
    static func resourcesURL() throws -> URL {
        let bundleName = "PodcastNotes_PodcastNotesApp.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName).appendingPathComponent("Resources"),
            Bundle.main.bundleURL.appendingPathComponent(bundleName).appendingPathComponent("Resources"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")
        ].compactMap { $0 }
        guard let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pipeline.py").path) }) else {
            throw PipelineError.resources("找不到独立 pipeline.py")
        }
        return match
    }

    static func runSync(_ arguments: [String]) throws -> String {
        let resources = try resourcesURL()
        let pipeline = resources.appendingPathComponent("pipeline.py")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbPath = appSupport.appendingPathComponent("PodcastNotes/podcast_notes.sqlite3").path
        let python = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [pipeline.path, "--db", dbPath, "--resources", resources.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.log")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }
        try stdoutHandle.close()
        try stderrHandle.close()
        let stdout = String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw PipelineError.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) { try runSync(arguments) }.value
    }
}
