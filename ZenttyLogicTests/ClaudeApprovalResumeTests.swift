import Foundation
import XCTest
@testable import Zentty

/// Reproduces the "Needs input while Claude is clearly working" symptom.
///
/// Live agent-bench trace (claude/approval_then_work, Claude Code 2.1.261):
///
///   PreToolUse(Write) → PermissionRequest(Write) → [user approves] →
///   Write runs → Read runs → Grep runs → PreToolUse(Bash) → Stop
///
/// Between the approval and the next Bash/Write/Edit PreToolUse there were
/// eleven seconds with zero hook events. Only Enter, a PreToolUse for the
/// narrow matcher set, or Stop ever cleared the approval prompt. Approving
/// with `1`/`y` and then working through Read/Grep/Agent tools left the pane
/// on "Needs input" for the whole stretch.
///
/// These tests drive the real Claude adapter through a fresh session store
/// and assert the reduced status after each PostToolUse.
///
/// Payload shapes mirror Claude Code 2.1.261: `PermissionRequest` carries
/// `tool_name` and `tool_input` but no `tool_use_id`; `PostToolUse` /
/// `PostToolUseFailure` carry `tool_use_id`, and the failure variant adds
/// `is_interrupt`.
final class ClaudeApprovalResumeTests: XCTestCase {

    private let defaultEnvironment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-approval-resume",
        "ZENTTY_PANE_ID": "pane-approval-resume",
        "ZENTTY_WINDOW_ID": "window-approval-resume",
        "ZENTTY_CLAUDE_PID": "4242",
    ]

    private var sessionStore: ClaudeHookSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-approval-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test_post_tool_use_after_approval_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Write","tool_use_id":"tu-write"}"#, into: &reducer, at: base + 4.7)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Write","message":"Create file ZENTTY_OK?"}"#, into: &reducer, at: base + 4.72)

        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.interactionKind, .approval)

        // User approved with `1` (no Enter, so no userSubmittedInput event).
        // The approved tool finishes: PostToolUse is the first hook Claude
        // Code emits after the permission was resolved.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Write","tool_use_id":"tu-write","tool_response":{"success":true}}"#, into: &reducer, at: base + 10.8)

        let afterWrite = reducer.reducedStatus(now: base + 11)
        XCTAssertEqual(afterWrite?.state, .running, "PostToolUse for the approved tool must clear the approval prompt. Got \(String(describing: afterWrite?.state)) text=\(afterWrite?.text ?? "nil")")
        XCTAssertEqual(afterWrite?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertNil(afterWrite?.text)

        // Read/Grep never fire PreToolUse (narrow matcher); PostToolUse keeps
        // the pane on running.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 14)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Grep","tool_use_id":"tu-grep"}"#, into: &reducer, at: base + 18)
        XCTAssertEqual(reducer.reducedStatus(now: base + 19)?.state, .running)

        try replay(#"{"hook_event_name":"Stop","session_id":"s1"}"#, into: &reducer, at: base + 23.8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 24)?.state, .idle)
    }

    func test_post_tool_use_failure_after_approval_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 2_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s2"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s2"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        try replay(#"{"hook_event_name":"PostToolUseFailure","session_id":"s2","tool_name":"Bash","tool_use_id":"tu-bash","error":"exit 2"}"#, into: &reducer, at: base + 9)
        XCTAssertEqual(reducer.reducedStatus(now: base + 10)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 10)?.interactionKind, PaneAgentInteractionKind.none)
    }

    func test_post_tool_use_for_sibling_tool_keeps_pending_approval_visible() throws {
        // Parallel tool batch: Read A and Bash B are issued together. B needs
        // permission; A completes while B's dialog is still open. A's
        // PostToolUse must not clear B's prompt.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 3_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s3"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s3"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s3","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s3","tool_name":"Bash","message":"Run rm -rf build?"}"#, into: &reducer, at: base + 1.02)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Read","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1.3)

        let status = reducer.reducedStatus(now: base + 2)
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .approval)
        XCTAssertEqual(status?.text, "Run rm -rf build?")

        // B's own completion clears it.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_permission_request_inherits_tool_use_id_from_preceding_pre_tool_use() throws {
        // PermissionRequest has no tool_use_id of its own. The PreToolUse for
        // the same tool call announced it moments earlier; that id is what
        // lets a sibling Read's PostToolUse be told apart from Bash's own.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 5_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s5"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s5","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s5","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s5"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-bash")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "Bash")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s5","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 1.3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.text, "Run make?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s5","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s5")?.lastStructuredInteractionToolName)
    }

    func test_permission_request_without_pre_tool_use_falls_back_to_tool_name() throws {
        // The PreToolUse matcher only covers Bash/Write/Edit. A WebFetch
        // prompt therefore has no id at all; the tool name is the only handle.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 6_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s6"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s6"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s6","tool_name":"WebFetch","message":"Fetch https://example.com?"}"#, into: &reducer, at: base + 1)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s6")?.lastStructuredInteractionToolUseID)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s6","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 1.3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.text, "Fetch https://example.com?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s6","tool_name":"WebFetch","tool_use_id":"tu-fetch"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_pre_tool_use_from_a_subagent_does_not_lend_its_id_to_the_parent_prompt() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 7_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s7"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s7","tool_name":"Bash","tool_use_id":"tu-sub","agent_id":"agent-1"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s7","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s7"))
        XCTAssertNil(record.lastStructuredInteractionToolUseID, "a subagent's PreToolUse must not be mistaken for the parent's prompted call")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "Bash")
    }

    func test_interrupted_post_tool_use_failure_emits_no_payload() throws {
        // Escape during a long Bash: Claude redraws the idle "✳" title at once
        // and no Stop hook follows. The late PostToolUseFailure carries
        // is_interrupt and must not push the pane back to running.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 8_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s8"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s8"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s8","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        let payloads = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash","error":"interrupted","is_interrupt":true,"duration_ms":4200}"#)
        XCTAssertTrue(payloads.isEmpty, "an interrupted tool must leave the pane state to title-based idle detection")
        XCTAssertNil(try sessionStore.lookup(sessionID: "s8")?.structuredInteractionKind, "the pending prompt is gone once the user interrupted")

        // A non-interrupt failure still resumes.
        let failure = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash","error":"exit 2","is_interrupt":false}"#)
        XCTAssertEqual(failure.first?.state, .running)
    }

    func test_post_tool_use_after_ask_user_question_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 4_000)
        let ask = #"""
        {"hook_event_name":"PreToolUse","session_id":"s4","tool_name":"AskUserQuestion","tool_use_id":"tu-ask",
         "tool_input":{"questions":[{"question":"Which approach?","options":[{"label":"A"},{"label":"B"}]}]}}
        """#

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s4"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s4"}"#, into: &reducer, at: base + 0.1)
        try replay(ask, into: &reducer, at: base + 1)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.interactionKind, .decision)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"AskUserQuestion","tool_use_id":"tu-ask"}"#, into: &reducer, at: base + 20)
        XCTAssertEqual(reducer.reducedStatus(now: base + 21)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 21)?.interactionKind, PaneAgentInteractionKind.none)
    }

    private func replay(_ json: String, into reducer: inout PaneAgentReducerState, at now: Date) throws {
        for payload in try makePayloads(json) {
            reducer.apply(payload, now: now)
        }
    }

    private func makePayloads(_ json: String) throws -> [AgentStatusPayload] {
        try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(json.utf8)),
            environment: defaultEnvironment,
            sessionStore: sessionStore
        )
    }
}

/// Terminal-title half of the same symptom. While a Claude Code permission or
/// AskUserQuestion dialog is open the title carries the idle glyph "✳"; the
/// moment the user answers (with `1`, `y`, Enter, or a click elsewhere) the
/// spinner glyphs "◐ ◑" come back — several seconds before any hook fires.
/// Live bench timeline (claude/approval_then_work):
///
///   4707 ms  title "✳ …"   (dialog open)
///   4721 ms  PermissionRequest
///  10737 ms  user types 1
///  10747 ms  title "◐ …"   ← resume signal
///  21893 ms  PreToolUse(Bash) — first hook after approval
@MainActor
final class ClaudeSpinnerTitleResumeTests: XCTestCase {

    func test_spinner_title_after_idle_title_resumes_blocked_claude_session() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Create file ZENTTY_OK?", interactionKind: .approval
            )
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        // Title stays on the idle glyph while the dialog is open: no change.
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        // User answers; spinner returns.
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        let status = store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus
        XCTAssertEqual(status?.state, .running, "spinner title after the idle-glyph dialog title must resume the session")
        XCTAssertEqual(status?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertNil(status?.text)
    }

    func test_spinner_resume_clears_pending_prompt_in_hook_session_store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-spinner-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            claudeHookSessionStoreProvider: { sessionStore }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        try sessionStore.rememberStructuredInteraction(
            sessionID: "session-claude-spinner",
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            cwd: "/tmp/project",
            pid: nil,
            text: "Create file ZENTTY_OK?",
            kind: .approval,
            confidence: .explicit,
            toolUseID: "tu-write",
            toolName: "Write"
        )

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Create file ZENTTY_OK?", interactionKind: .approval
            )
        )
        XCTAssertEqual(try sessionStore.lookup(sessionID: "session-claude-spinner")?.structuredInteractionKind, .approval)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "session-claude-spinner"))
        XCTAssertNil(record.structuredInteractionKind, "the bridge must forget the answered prompt or it keeps dropping PostToolUse for the rest of the turn")
        XCTAssertNil(record.lastStructuredInteractionToolUseID)
        XCTAssertNil(record.lastStructuredInteractionToolName)
    }

    func test_stale_spinner_title_before_dialog_title_does_not_clear_prompt() throws {
        // Reverse race: PermissionRequest lands before the "✳" title does. The
        // spinner glyph that is still on screen must not be read as a resume.
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Run make?", interactionKind: .approval
            )
        )
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◑ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Run make?")
    }

    private func metadata(title: String) -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: "main"
        )
    }

    private func claudePayload(
        paneID: PaneID,
        worklaneID: WorklaneID,
        state: PaneAgentState,
        text: String? = nil,
        interactionKind: PaneAgentInteractionKind? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: text,
            lifecycleEvent: .update,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: "session-claude-spinner",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}
