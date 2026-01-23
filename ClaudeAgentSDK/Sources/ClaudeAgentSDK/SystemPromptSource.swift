//
//  SystemPromptSource.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-12-16.
//

import Foundation

/// How to provide the system prompt to Claude Code CLI
public enum SystemPromptSource: Sendable {
    /// Provide system prompt as inline text (uses --system-prompt flag)
    case text(String)
    /// Provide system prompt from a file path (uses --system-prompt-file flag)
    case file(URL)
}
