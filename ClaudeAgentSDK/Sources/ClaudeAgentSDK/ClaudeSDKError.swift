//
//  ClaudeSDKError.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-11-29.
//

import Foundation

public enum ClaudeSDKError: Error, LocalizedError {
    case cliNotFound(searchedPaths: [String])
    case workingDirectoryNotFound(path: String)
    case processLaunchFailed(underlying: Error)
    case processExited(code: Int32, stderr: String?)
    case jsonParseError(line: String, underlying: Error)
    case sessionNotReady
    case outputDecodingFailed(type: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let paths):
            return "Claude Code CLI not found. Searched: \(paths.joined(separator: ", ")). Install with: curl -fsSL https://claude.ai/install.sh | bash"
        case .workingDirectoryNotFound(let path):
            return "Working directory not found: \(path)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude Code: \(error.localizedDescription)"
        case .processExited(let code, let stderr):
            return "Claude Code exited with code \(code)\(stderr.map { ": \($0)" } ?? "")"
        case .jsonParseError(let line, _):
            return "Failed to parse JSON: \(line.prefix(100))..."
        case .sessionNotReady:
            return "Session not ready for communication"
        case .outputDecodingFailed(let type, let error):
            return "Failed to decode output as \(type): \(error.localizedDescription)"
        }
    }
}
