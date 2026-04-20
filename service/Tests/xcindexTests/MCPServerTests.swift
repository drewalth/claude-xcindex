import Foundation
import MCP
import Testing
@testable import xcindex

/// Covers the MCP-facing dispatch layer for `plan_rename`: the tool
/// name, argument parsing, and error-text shape visible to Claude.
/// Deeper planning behavior is exercised by `RenamePlannerTests` and
/// `RequestProcessorTests`; this suite only proves the Dispatcher is
/// wired correctly and produces the expected user-visible strings.
@Suite("MCPServer.Dispatcher")
struct MCPServerDispatcherTests {
    @Test("plan_rename without newName surfaces a structured error")
    func planRenameMissingNewName() async {
        let processor = RequestProcessor()
        let args: [String: Value] = [
            "usr": .string("s:example"),
        ]
        let result = await Dispatcher.handle(
            name: "plan_rename",
            arguments: args,
            processor: processor
        )

        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text.contains("newName"), "expected error text to mention newName, got: \(text)")
    }

    @Test("plan_rename without usr surfaces a structured error")
    func planRenameMissingUSR() async {
        let processor = RequestProcessor()
        let args: [String: Value] = [
            "newName": .string("Renamed"),
        ]
        let result = await Dispatcher.handle(
            name: "plan_rename",
            arguments: args,
            processor: processor
        )

        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text.contains("usr"), "expected error text to mention usr, got: \(text)")
    }

    @Test("unknown tool name returns an isError result")
    func unknownTool() async {
        let processor = RequestProcessor()
        let result = await Dispatcher.handle(
            name: "not_a_tool",
            arguments: nil,
            processor: processor
        )

        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text.contains("not_a_tool"))
    }

    private func firstText(_ content: [Tool.Content]) -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        return ""
    }
}
