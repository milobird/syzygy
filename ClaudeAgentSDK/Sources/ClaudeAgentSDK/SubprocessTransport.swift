//
//  SubprocessTransport.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-11-29.
//

import Foundation

/// Manages Claude Code CLI subprocess
public actor SubprocessTransport {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var isReady = false

    private let cliPath: String
    private let workingDirectory: URL
    private let model: String?
    private let systemPrompt: SystemPromptSource?
    private let outputSchema: String?
    private let logger: ClaudeLogger?

    public init(
        workingDirectory: URL,
        model: String? = nil,
        systemPrompt: SystemPromptSource? = nil,
        outputSchema: String? = nil,
        logger: ClaudeLogger? = nil
    ) throws {
        self.workingDirectory = workingDirectory
        self.model = model
        self.systemPrompt = systemPrompt
        self.outputSchema = outputSchema
        self.logger = logger
        self.cliPath = try Self.findCLI()

        logger?("Found CLI at: \(cliPath)", .info)
        logger?("Working directory: \(workingDirectory.path)", .info)

        guard FileManager.default.fileExists(atPath: workingDirectory.path) else {
            throw ClaudeSDKError.workingDirectoryNotFound(path: workingDirectory.path)
        }
    }

    /// Start the subprocess
    public func connect() async throws {
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = workingDirectory
        let args = buildArguments()
        process.arguments = args
        process.environment = buildEnvironment()

        logger?("Arguments: \(args.joined(separator: " "))", .info)

        // Setup pipes
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading

        // Capture stderr for logging
        if let logger = self.logger {
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    logger("stderr: \(text)", .error)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.isReady = true
            logger?("Process started (PID: \(process.processIdentifier))", .info)
        } catch {
            logger?("Process launch failed: \(error)", .error)
            throw ClaudeSDKError.processLaunchFailed(underlying: error)
        }
    }

    /// Write a message to stdin (JSONL format)
    public func write(_ message: InputMessage) throws {
        guard isReady, let stdin else {
            logger?("Cannot write: session not ready", .error)
            throw ClaudeSDKError.sessionNotReady
        }

        let encoder = JSONEncoder()
        var data = try encoder.encode(message)
        data.append(contentsOf: "\n".utf8) // JSONL newline

        if let jsonString = String(data: data, encoding: .utf8) {
            logger?("Writing to stdin: \(jsonString.trimmingCharacters(in: .newlines))", .sent)
        }

        stdin.write(data)
    }

    /// Create async stream of stdout data
    public func stdoutStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard let stdout else {
                continuation.finish()
                return
            }

            stdout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }

            continuation.onTermination = { _ in
                stdout.readabilityHandler = nil
            }
        }
    }

    /// Close stdin to signal end of input
    public func endInput() {
        try? stdin?.close()
        stdin = nil
    }

    /// Terminate the process
    public func close() {
        isReady = false

        // Clear handlers BEFORE closing to prevent callbacks during teardown
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil

        endInput()

        if process?.isRunning == true {
            process?.terminate()
        }

        try? stdout?.close()
        try? stderr?.close()

        process = nil
        stdout = nil
        stderr = nil
    }

    // MARK: - Public Utilities

    /// Common paths where binaries are installed on macOS
    /// Used both for finding the CLI and setting up subprocess PATH
    public static func commonBinaryPaths() -> [String] {
        let homeDir = NSHomeDirectory()

        var paths = [
            "\(homeDir)/.local/bin",               // Official Claude installer / user local
            "/opt/homebrew/bin",                   // Homebrew (Apple Silicon)
            "/usr/local/bin",                      // Homebrew (Intel) / common installs
            "\(homeDir)/.volta/bin",               // Volta
            "\(homeDir)/.fnm/aliases/default/bin", // fnm
            "\(homeDir)/.npm-global/bin",          // npm with custom prefix
            "\(homeDir)/.yarn/bin",                // Yarn
            "/usr/bin",
            "/bin"
        ]

        // Add nvm paths (check installed versions, newest first)
        let nvmDir = "\(homeDir)/.nvm/versions/node"
        if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for version in nodeVersions.sorted().reversed() {
                paths.append("\(nvmDir)/\(version)/bin")
            }
        }

        return paths
    }

    private func buildArguments() -> [String] {
        // TODO: Replace --dangerously-skip-permissions with hook-based permission handling
        // See: https://code.claude.com/docs/en/hooks
        // --print enables non-interactive mode (required for --input-format and --output-format)
        // --verbose is required when using --output-format=stream-json with --print
        var args = [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--dangerously-skip-permissions",
            "--setting-sources", "project"
        ]

        if let systemPrompt {
            switch systemPrompt {
            case .text(let text):
                args += ["--system-prompt", text]
            case .file(let url):
                args += ["--system-prompt-file", url.path]
            }
        }

        if let model {
            args += ["--model", model]
        }

        if let outputSchema {
            args += ["--json-schema", outputSchema]
        }

        return args
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = workingDirectory.path

        // Disable background tasks - Spoke Specs manages the full conversation lifecycle
        // and doesn't support async task checking or Ctrl+B shortcuts
        env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"

        // macOS apps don't inherit the user's shell PATH, so prepend common paths
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = (Self.commonBinaryPaths() + [existingPath]).joined(separator: ":")

        return env
    }

    private static func findCLI() throws -> String {
        // Search common binary paths for claude executable
        let searchPaths = commonBinaryPaths().map { "\($0)/claude" }

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw ClaudeSDKError.cliNotFound(searchedPaths: searchPaths)
    }
}
