//
//  StreamJSONParser.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-11-29.
//

import Foundation

// MARK: - Incoming Messages

/// System message from CLI (we only care about result subtype)
public struct SystemMessage: Decodable, Sendable {
    public let type: String
    public let subtype: String
    public let result: String?
    public let structuredOutput: AnyCodableValue?  // The actual structured output
    public let sessionId: String?
    public let totalCostUsd: Double?
    public let durationMs: Int?
    public let numTurns: Int?

    enum CodingKeys: String, CodingKey {
        case type, subtype, result
        case structuredOutput = "structured_output"
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case durationMs = "duration_ms"
        case numTurns = "num_turns"
    }

    public var isResult: Bool { type == "result" && subtype == "success" }
}

/// Type-erased JSON value for structured_output
public struct AnyCodableValue: Decodable, Sendable {
    public let jsonString: String

    public init(from decoder: Decoder) throws {
        // Decode as generic JSON and re-encode to string
        let container = try decoder.singleValueContainer()
        let jsonObject = try container.decode(JSONValue.self)
        let data = try JSONEncoder().encode(jsonObject)
        self.jsonString = String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Helper enum for decoding arbitrary JSON
private enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Outgoing Messages

/// Inner message structure with role and content
public struct MessageContent: Encodable, Sendable {
    public let role = "user"
    public let content: String

    public init(_ text: String) {
        self.content = text
    }
}

/// Message sent to CLI via stdin (format: {"type": "user", "message": {"role": "user", "content": "..."}})
public struct InputMessage: Encodable, Sendable {
    public let type = "user"
    public let message: MessageContent

    public init(_ text: String) {
        self.message = MessageContent(text)
    }
}

// MARK: - Parser

/// Parses JSONL stream from CLI stdout, looking for the result message
public actor StreamJSONParser {
    private var buffer = Data()
    private var searchOffset = 0  // Where to start searching for newline (already scanned before this)
    private let maxBufferSize = 50 * 1024 * 1024 // 50MB limit (Ask Spoke responses can be large)
    private let newline = UInt8(ascii: "\n")

    public init() {}

    /// Feed raw data from stdout, emitting complete JSONL lines via callback
    /// - Parameters:
    ///   - data: Raw data chunk from stdout
    ///   - onLine: Called for each complete JSONL line (for logging/processing)
    /// - Returns: Result JSON string if the final result message was found
    public func feed(_ data: Data, onLine: ((String) -> Void)? = nil) throws -> String? {
        buffer.append(data)  // O(1) amortized - Data uses exponential growth

        guard buffer.count <= maxBufferSize else {
            buffer = Data()
            searchOffset = 0
            throw ClaudeSDKError.jsonParseError(
                line: "Buffer exceeded \(maxBufferSize) bytes",
                underlying: NSError(domain: "BufferOverflow", code: 1)
            )
        }

        // Process complete lines, searching only from where we left off
        while searchOffset < buffer.count,
              let newlineIndex = buffer[searchOffset...].firstIndex(of: newline) {
            // Extract line data (excluding newline)
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])
            searchOffset = 0  // Reset after extracting a line

            // Convert to string only for complete lines
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces),
                  !line.isEmpty else { continue }

            // Emit complete line for logging
            onLine?(line)

            // Try to parse as system message with result
            if let result = tryParseResult(line) {
                return result
            }
        }

        // No newline found - remember where we searched up to
        searchOffset = buffer.count

        return nil
    }

    private func tryParseResult(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(SystemMessage.self, from: data),
              message.isResult,
              let structuredOutput = message.structuredOutput else {
            return nil
        }
        return structuredOutput.jsonString
    }
}
