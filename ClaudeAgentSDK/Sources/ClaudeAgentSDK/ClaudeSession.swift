//
//  ClaudeSession.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-11-29.
//

import Foundation

/// Logger closure type for debugging
public typealias ClaudeLogger = @Sendable (String, LogLevel) -> Void

/// Log levels for ClaudeLogger
public enum LogLevel: String, Sendable {
    case info
    case sent
    case received
    case error
}

/// A session with Claude Code CLI for multi-turn conversations
public final class ClaudeSession: Sendable {
    private let transport: SubprocessTransport
    private let parser: StreamJSONParser
    private let logger: ClaudeLogger?

    /// The working directory for this session
    public let workingDirectory: URL

    /// Initialize a session
    /// - Parameters:
    ///   - workingDirectory: Directory for Claude to operate in (inherits CLAUDE.md, tools)
    ///   - model: Model alias ("sonnet", "opus") or full model name
    ///   - systemPrompt: System prompt source (replaces the default system prompt entirely)
    ///   - outputSchema: JSON schema for structured output (as JSON string)
    ///   - logger: Optional logger for debugging (receives message and level)
    public init(
        workingDirectory: URL,
        model: String? = nil,
        systemPrompt: SystemPromptSource? = nil,
        outputSchema: String? = nil,
        logger: ClaudeLogger? = nil
    ) async throws {
        self.workingDirectory = workingDirectory
        self.logger = logger
        self.transport = try SubprocessTransport(
            workingDirectory: workingDirectory,
            model: model,
            systemPrompt: systemPrompt,
            outputSchema: outputSchema,
            logger: logger
        )
        self.parser = StreamJSONParser()

        logger?("Connecting to Claude Code CLI...", .info)
        try await transport.connect()
        logger?("Connected successfully", .info)
    }

    /// Send a prompt and await structured response
    /// - Parameter prompt: User message text
    /// - Returns: Decoded response of type T
    public func respond<T: Decodable & Sendable>(to prompt: String) async throws -> T {
        // Send user message
        let message = InputMessage(prompt)
        logger?("Sending prompt (\(prompt.count) chars)", .sent)
        try await transport.write(message)

        // Read stdout until we get a result
        for await data in await transport.stdoutStream() {
            // Feed raw data to parser - it handles buffering efficiently
            // Only complete JSONL lines are converted to String
            let resultJSON = try await parser.feed(data) { [logger] line in
                logger?(line, .received)
            }

            if let resultJSON {
                logger?("Got result JSON (\(resultJSON.count) chars)", .info)

                // Got the result — decode as T
                guard let data = resultJSON.data(using: .utf8) else {
                    logger?("Failed to convert result to UTF8 data", .error)
                    throw ClaudeSDKError.outputDecodingFailed(
                        type: String(describing: T.self),
                        underlying: NSError(domain: "UTF8", code: 1)
                    )
                }

                do {
                    let result = try JSONDecoder().decode(T.self, from: data)
                    logger?("Successfully decoded \(T.self)", .info)
                    return result
                } catch {
                    logger?("Decoding failed: \(error)", .error)
                    throw ClaudeSDKError.outputDecodingFailed(
                        type: String(describing: T.self),
                        underlying: error
                    )
                }
            }
        }

        // Stream ended without result
        logger?("Stream ended without result", .error)
        throw ClaudeSDKError.processExited(code: -1, stderr: "No result received")
    }

    /// End the session and cleanup resources
    public func close() async {
        await transport.close()
    }

    /// Synchronously terminate the session (for use in applicationWillTerminate)
    /// Blocks until transport closes or timeout expires
    public nonisolated func terminateSync(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await transport.close()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    deinit {
        terminateSync(timeout: 1.0)
    }
}
