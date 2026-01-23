//
//  StreamJSONParserTests.swift
//  ClaudeAgentSDK
//
//  Created by Milo Bird on 2025-11-29.
//

import Foundation
import Testing
@testable import ClaudeAgentSDK

struct StreamJSONParserTests {
    @Test func returnsNilForNonResultMessages() async throws {
        let parser = StreamJSONParser()
        let line = #"{"type":"system","subtype":"init"}"# + "\n"

        let result = try await parser.feed(Data(line.utf8))

        #expect(result == nil)
    }

    @Test func extractsResultFromResultMessage() async throws {
        let parser = StreamJSONParser()
        // Correct format: type="result", subtype="success", structured_output contains the data
        let line = #"{"type":"result","subtype":"success","structured_output":{"summary":"test"}}"# + "\n"

        let result = try await parser.feed(Data(line.utf8))

        #expect(result != nil)
        #expect(result?.contains("summary") == true)
        #expect(result?.contains("test") == true)
    }

    @Test func buffersPartialLines() async throws {
        let parser = StreamJSONParser()

        // Feed partial JSON (first half of a complete message)
        let result1 = try await parser.feed(Data("{\"type\":\"result\",\"subtype\":\"success\"".utf8))
        #expect(result1 == nil)

        // Complete the line
        let result2 = try await parser.feed(Data(",\"structured_output\":{\"done\":true}}\n".utf8))
        #expect(result2 != nil)
        #expect(result2?.contains("done") == true)
    }

    @Test func ignoresAssistantAndUserMessages() async throws {
        let parser = StreamJSONParser()
        // Each line must end with newline for parser to process it
        let lines = "{\"type\":\"user\",\"content\":\"hello\"}\n" +
                    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n" +
                    "{\"type\":\"result\",\"subtype\":\"success\",\"structured_output\":{}}\n"

        let result = try await parser.feed(Data(lines.utf8))

        #expect(result == "{}")
    }

    @Test func throwsOnBufferOverflow() async throws {
        let parser = StreamJSONParser()
        let hugeData = Data(count: 51 * 1024 * 1024)  // 51MB exceeds 50MB limit

        await #expect(throws: ClaudeSDKError.self) {
            _ = try await parser.feed(hugeData)
        }
    }

    @Test func handlesLargeBase64EfficientlyInChunks() async throws {
        let parser = StreamJSONParser()

        // Simulate large base64 data arriving in chunks (like real stdout)
        let prefix = #"{"type":"result","subtype":"success","structured_output":{"data":""#
        let base64Content = String(repeating: "QUFBQUFBQUFBQUFBQUFBQQ==", count: 10000)  // ~240KB
        let suffix = "\"}}\n"

        // Feed in chunks to simulate real streaming
        let fullLine = prefix + base64Content + suffix
        let chunkSize = 64 * 1024  // 64KB chunks like real pipe reads

        var offset = 0
        var result: String?
        while offset < fullLine.count {
            let endIndex = min(offset + chunkSize, fullLine.count)
            let chunk = String(fullLine[fullLine.index(fullLine.startIndex, offsetBy: offset)..<fullLine.index(fullLine.startIndex, offsetBy: endIndex)])
            result = try await parser.feed(Data(chunk.utf8))
            if result != nil { break }
            offset = endIndex
        }

        #expect(result != nil)
        #expect(result?.contains("data") == true)
    }
}
