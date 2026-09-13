import Foundation
import XCTest
@testable import Zentty

/// Devin CLI hooks are Claude Code-format compatible; these tests pin the
/// differences that motivated a dedicated adapter: slug session ids, no
/// Subagent* events (lifecycle inferred from `run_subagent` tool calls), and
/// task progress derived from `todo_write.tool_input`.
final class DevinEventAdapterTests: XCTestCase {

    private let defaultEnvironment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-1",
        "ZENTTY_PANE_ID": "pane-1",
        "ZENTTY_WINDOW_ID": "window-1",
    ]

    private final class Harness {
        let sessionStore: ClaudeHookSessionStore
        let subagentStore: AgentSubagentRegistryStore
        var environment: [String: String]

        init(environment: [String: String]) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zentty-devin-bridge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessionStore = ClaudeHookSessionStore(
                stateURL: directory.appendingPathComponent("devin-hook-sessions.json", isDirectory: false)
            )
            subagentStore = AgentSubagentRegistryStore(
                stateURL: directory.appendingPathComponent("devin-subagent-sessions.json", isDirectory: false),
                transcriptModificationDate: { _ in nil }
            )
            self.environment = environment
        }

        func payloads(for json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.devinAdapter(
                data: Data(json.utf8),
                environment: environment,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }
    }

    private func makeHarness(pid: String? = nil) throws -> Harness {
        var environment = defaultEnvironment
        if let pid { environment["ZENTTY_DEVIN_PID"] = pid }
        return try Harness(environment: environment)
    }

    // MARK: - Lifecycle

    func test_devin_adapter_fails_open_on_malformed_payload() {
        var postedPayloads: [AgentStatusPayload] = []
        var loggedErrors: [String] = []

        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=devin"],
            environment: defaultEnvironment,
            inputData: Data("{ not valid json".utf8),
            post: { postedPayloads.append($0) },
            writeError: { loggedErrors.append(String(describing: $0)) }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertTrue(loggedErrors.isEmpty)
    }

    func test_devin_adapter_session_start_attaches_slug_session_and_pid() throws {
        let harness = try makeHarness(pid: "4242")
        let payloads = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"thorn-angora","cwd":"/tmp/project"}"#)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].state, .starting)
        XCTAssertEqual(payloads[0].toolName, "Devin")
        XCTAssertEqual(payloads[0].sessionID, "thorn-angora")
        XCTAssertEqual(payloads[0].agentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pid, 4242)
        XCTAssertEqual(payloads[1].pidEvent, .attach)
    }

    func test_devin_adapter_user_prompt_submit_sets_running() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"thorn-angora"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"UserPromptSubmit","session_id":"thorn-angora","prompt":"hi"}"#)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].sessionID, "thorn-angora")
    }

    func test_devin_adapter_pre_tool_use_sets_running() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"exec_0","tool_input":{"command":"ls"}}"#)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
    }

    func test_devin_adapter_stop_maps_to_idle() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1","last_assistant_message":"done"}"#)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].toolName, "Devin")
    }

    func test_devin_adapter_post_compaction_sets_running() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"PostCompaction","session_id":"s-1"}"#)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].text, "Compacted")
    }

    func test_devin_adapter_session_end_clears_state_and_pid() throws {
        let harness = try makeHarness(pid: "4242")
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"thorn-angora"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"SessionEnd","session_id":"thorn-angora","reason":"complete"}"#)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[0].sessionID, "thorn-angora")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
    }

    // MARK: - Interactions

    func test_devin_adapter_permission_request_maps_to_needs_input() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"exec","tool_input":{"command":"rm -rf build"}}"#)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Devin wants to run exec: rm -rf build")
    }

    func test_devin_adapter_ask_user_question_maps_to_needs_input() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s-1",
          "tool_name": "ask_user_question",
          "tool_use_id": "ask_user_question_0",
          "tool_input": {
            "questions": [{"question": "Which approach?", "header": "Approach"}]
          }
        }
        """
        let payloads = try harness.payloads(for: json)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .decision)
        XCTAssertEqual(payloads[0].text, "Which approach?")
    }

    // MARK: - Task progress

    func test_devin_adapter_todo_write_post_tool_use_reports_progress() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let json = """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "s-1",
          "tool_name": "todo_write",
          "tool_use_id": "todo_write_0",
          "tool_input": {
            "todos": [
              {"content": "First", "status": "completed"},
              {"content": "Second", "status": "in_progress"},
              {"content": "Third", "status": "pending"}
            ]
          },
          "tool_response": {"output": "ok"}
        }
        """
        let payloads = try harness.payloads(for: json)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(
            payloads[0].taskProgress,
            PaneAgentTaskProgress(items: [
                PaneAgentTaskItem(title: "First", status: .done),
                PaneAgentTaskItem(title: "Second", status: .inProgress),
                PaneAgentTaskItem(title: "Third", status: .pending),
            ])
        )
    }

    // MARK: - Subagents

    func test_devin_adapter_run_subagent_foreground_tracks_lifecycle() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        let pre = try harness.payloads(for: """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "Explore", "profile": "subagent_explore", "task": "list files", "is_background": false}
        }
        """)
        XCTAssertEqual(pre.count, 1)
        XCTAssertEqual(pre[0].subagents?.count, 1)
        XCTAssertEqual(pre[0].subagents?.entries.first?.agentType, "subagent_explore")
        XCTAssertEqual(pre[0].subagents?.entries.first?.model, "swe-1-6")
        XCTAssertEqual(pre[0].subagents?.entries.first?.nickname, "Explore")

        let post = try harness.payloads(for: """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "Explore", "profile": "subagent_explore", "task": "list files", "is_background": false},
          "tool_response": {"output": "Subagent agent_id=e4ee finished."}
        }
        """)
        XCTAssertEqual(post.count, 1)
        XCTAssertEqual(post[0].subagents?.count, 0)
    }

    func test_devin_adapter_run_subagent_background_rekeys_to_agent_id() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)

        _ = try harness.payloads(for: """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "BG", "profile": "subagent_general", "task": "work", "is_background": true}
        }
        """)
        let post = try harness.payloads(for: """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "BG", "profile": "subagent_general", "task": "work", "is_background": true},
          "tool_response": {"output": "Background subagent started with agent_id=ab12cd34. Use read_subagent to check on it."}
        }
        """)
        // Still running — the subagent is alive in the background, re-keyed to
        // the real agent id so a later read_subagent completion can retire it.
        XCTAssertEqual(post.first?.subagents?.count, 1)
        XCTAssertEqual(post.first?.subagents?.entries.first?.id, "ab12cd34")
        XCTAssertEqual(post.first?.subagents?.entries.first?.agentType, "subagent_general")
        XCTAssertNil(post.first?.subagents?.entries.first?.model)

        let stop = try harness.payloads(for: """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "s-1",
          "tool_name": "read_subagent",
          "tool_use_id": "read_subagent_0",
          "tool_input": {"agent_id": "ab12cd34"},
          "tool_response": {"output": "Subagent ab12cd34 completed."}
        }
        """)
        XCTAssertEqual(stop.first?.subagents?.count, 0)
    }

    func test_devin_adapter_stop_with_open_run_subagent_does_not_go_idle() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        _ = try harness.payloads(for: """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "FG", "profile": "subagent_explore", "task": "work", "is_background": false}
        }
        """)

        // The subagent's own Stop shares the parent's session_id/prompt_id and
        // carries no agent_id. While the run_subagent call is still open, a
        // Stop is the subagent's turn end — the pane must not go idle.
        let stop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertFalse(stop.contains { $0.state == .idle })
    }

    func test_devin_adapter_overlapping_foreground_subagent_stops_preserve_parent_slots() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        for id in ["first", "second"] {
            _ = try harness.payloads(for: """
            {"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"\(id)","tool_input":{"is_background":false}}
            """)
        }

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: "s-1")?.preToolUseSlots(agentID: nil).count, 2)
        let firstCompletion = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"first","tool_input":{"is_background":false}}"#)
        XCTAssertEqual(firstCompletion.first?.subagents?.count, 1)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#).isEmpty)
        let secondCompletion = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"second","tool_input":{"is_background":false}}"#)
        XCTAssertEqual(secondCompletion.first?.subagents?.count, 0)
        XCTAssertEqual(try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#).first?.state, .idle)
    }

    func test_devin_adapter_child_stop_and_sibling_completion_preserve_parent_approval() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":false}}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"approval"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"exec","tool_use_id":"approval","tool_input":{"command":"deploy"}}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind, .approval)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":false}}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind, .approval)

        let approved = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"approval"}"#)
        XCTAssertEqual(approved.first?.state, .running)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind)
    }

    func test_devin_adapter_stop_with_background_subagent_retires_oldest() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        _ = try harness.payloads(for: """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "BG", "profile": "subagent_explore", "task": "work", "is_background": true}
        }
        """)
        _ = try harness.payloads(for: """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "s-1",
          "tool_name": "run_subagent",
          "tool_use_id": "run_subagent_0",
          "tool_input": {"title": "BG", "profile": "subagent_explore", "task": "work", "is_background": true},
          "tool_response": {"output": "Background subagent started with agent_id=zz99."}
        }
        """)
        // Parent keeps working: another tool call opens, then the background
        // subagent's Stop arrives while that call is still in flight.
        _ = try harness.payloads(for: """
        {"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"exec_0","tool_input":{"command":"ls"}}
        """)

        let stop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        // Oldest subagent retired, pane still running (exec_0 is open).
        XCTAssertEqual(stop.first?.state, .running)
        XCTAssertEqual(stop.first?.subagents?.count, 0)
    }

    func test_devin_adapter_background_stop_preserves_pending_approval_and_updates_badge() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":true}}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":true},"tool_response":{"output":"agent_id=ab12"}}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"sibling"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"exec","tool_use_id":"approval","tool_input":{"command":"deploy"}}"#)

        let stop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertEqual(stop.first?.state, .needsInput)
        XCTAssertEqual(stop.first?.interactionKind, .approval)
        XCTAssertEqual(stop.first?.text, "Devin wants to run exec: deploy")
        XCTAssertEqual(stop.first?.subagents?.count, 0)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind, .approval)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"sibling"}"#).isEmpty)
    }

    func test_devin_adapter_background_stop_during_approval_without_open_slots_preserves_prompt() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"s-1"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":true}}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","session_id":"s-1","tool_name":"run_subagent","tool_use_id":"child","tool_input":{"is_background":true},"tool_response":{"output":"agent_id=ab12"}}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"exec","tool_use_id":"approval"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"exec","tool_use_id":"approval","tool_input":{"command":"deploy"}}"#)
        XCTAssertTrue(try XCTUnwrap(harness.sessionStore.lookup(sessionID: "s-1")).preToolUseSlots(agentID: nil).isEmpty)

        let stop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertEqual(stop.first?.state, .needsInput)
        XCTAssertEqual(stop.first?.interactionKind, .approval)
        XCTAssertEqual(stop.first?.text, "Devin wants to run exec: deploy")
        XCTAssertEqual(stop.first?.subagents?.count, 0)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind, .approval)

        let parentStop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        XCTAssertEqual(parentStop.first?.state, .idle)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: "s-1")?.structuredInteractionKind)
    }

    func test_devin_adapter_unknown_hook_event_returns_empty() throws {
        let harness = try makeHarness()
        let payloads = try harness.payloads(for: #"{"hook_event_name":"Notification","session_id":"s-1"}"#)
        XCTAssertTrue(payloads.isEmpty)
    }
}
