import Foundation
import XCTest
@testable import Zentty

final class AgentSubagentTrackingTests: XCTestCase {
    private let environment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-main",
        "ZENTTY_PANE_ID": "worklane-main-shell",
    ]

    private let paneKey = AgentSubagentRegistryStore.Key(
        tool: "claude",
        worklaneID: WorklaneID("worklane-main"),
        paneID: PaneID("worklane-main-shell")
    )

    // MARK: - Model labels

    func test_model_label_shortens_known_families() {
        XCTAssertEqual(AgentModelLabel.short(from: "claude-opus-5"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-sonnet-5"), "sonnet")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-fable-5-1"), "fable")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-haiku-4-5-20251001"), "haiku")
        XCTAssertEqual(AgentModelLabel.short(from: "opus"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "sonnet[1m]"), "sonnet")
        XCTAssertEqual(AgentModelLabel.short(from: "us.anthropic.claude-opus-5-v1:0"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-6-astra"), "astra")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-sol"), "sol")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-terra"), "terra")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-luna"), "luna")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.3-codex-spark"), "codex-spark")
        XCTAssertEqual(AgentModelLabel.short(from: "codex-auto-review"), "auto-review")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.4-mini"), "gpt-5.4-mini")
        XCTAssertNil(AgentModelLabel.short(from: "   "))
    }

    // MARK: - Summary

    func test_summary_groups_by_model_and_type_most_numerous_first() {
        let summary = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "b", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "c", agentType: "codex-review", model: "claude-sonnet-5"),
            PaneAgentSubagentEntry(id: "d", agentType: "worker", model: "gpt-6-astra", nickname: "Dirac"),
        ])

        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.badgeText, "4")
        XCTAssertEqual(summary.tooltipText, "4 subagents\nClick for details")
        let groups = summary.groups
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups[0].modelText, "opus")
        XCTAssertEqual(groups[0].trailingText, "general-purpose")
        XCTAssertEqual(groups[1].modelText, "astra")
        XCTAssertEqual(groups[1].trailingText, "worker · Dirac")
        XCTAssertEqual(groups[2].modelText, "sonnet")
        XCTAssertEqual(groups[2].leadingText, "1 ×")
    }

    func test_summary_without_model_shows_placeholder() {
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", agentType: "Explore")])
        XCTAssertEqual(summary.tooltipText, "1 subagent\nClick for details")
        XCTAssertEqual(summary.groups.first?.modelText, "model?")
    }

    func test_payload_user_info_round_trips_subagents_including_explicit_empty() throws {
        let summary = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "agent-1", agentType: "Explore", model: "claude-sonnet-5", transcriptPath: "/tmp/agent-1.jsonl"),
        ])
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane"),
            state: .running,
            toolName: "Claude Code",
            text: nil,
            subagents: summary,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let decoded = try AgentStatusPayload(userInfo: XCTUnwrap(payload.notificationUserInfo))
        XCTAssertEqual(decoded.subagents, summary)

        let cleared = payload.with(subagents: .empty)
        let decodedCleared = try AgentStatusPayload(userInfo: XCTUnwrap(cleared.notificationUserInfo))
        XCTAssertEqual(decodedCleared.subagents, .empty)

        let untouched = payload.with(subagents: nil)
        let decodedUntouched = try AgentStatusPayload(userInfo: XCTUnwrap(untouched.notificationUserInfo))
        XCTAssertNil(decodedUntouched.subagents)
    }

    // MARK: - Registry store

    func test_registry_tracks_start_stop_and_clear() throws {
        let store = try makeRegistryStore()

        let afterFirst = try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore"))
        XCTAssertEqual(afterFirst.count, 1)
        let afterSecond = try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", agentType: "Plan", model: "claude-opus-5"))
        XCTAssertEqual(afterSecond.count, 2)

        let afterStop = try store.stop(key: paneKey, subagentID: "a")
        XCTAssertEqual(afterStop.entries.map(\.id), ["b"])

        let afterUnknownStop = try store.stop(key: paneKey, subagentID: "zzz")
        XCTAssertEqual(afterUnknownStop.count, 1, "stopping an unknown id must not retire a live subagent")

        let afterAnonymousStop = try store.stop(key: paneKey, subagentID: nil)
        XCTAssertEqual(afterAnonymousStop.count, 0, "a stop without id retires the oldest subagent")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "c"))
        XCTAssertEqual(try store.clear(key: paneKey), .empty)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)

        try store.remove(key: paneKey)
        XCTAssertNil(try store.summary(key: paneKey))
    }

    func test_registry_merges_repeated_start_and_refreshes_missing_models() throws {
        let store = try makeRegistryStore()
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore", transcriptPath: "/tmp/a.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", model: "claude-sonnet-5"))
        let merged = try XCTUnwrap(try store.summary(key: paneKey)?.entries.first)
        XCTAssertEqual(merged.agentType, "Explore")
        XCTAssertEqual(merged.model, "claude-sonnet-5")
        XCTAssertEqual(merged.transcriptPath, "/tmp/a.jsonl")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", agentType: "Plan"))
        var resolvedIDs: [String] = []
        let refreshed = try store.refreshMissingModels(key: paneKey) { entry in
            resolvedIDs.append(entry.id)
            return entry.with(model: "claude-opus-5")
        }
        XCTAssertEqual(resolvedIDs, ["b"], "only entries without a model are resolved")
        XCTAssertEqual(refreshed?.entries.first(where: { $0.id == "b" })?.model, "claude-opus-5")
    }

    func test_registry_prunes_stale_entries_and_remembers_root_session() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try makeRegistryStore(now: { now })
        try store.recordRootSession(key: paneKey, sessionID: "root-1")
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "old"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow + 1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "fresh"))

        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["fresh"])
        XCTAssertEqual(try store.rootSessionID(key: paneKey), "root-1")
    }

    func test_registry_tracked_stop_ignores_unknown_and_consumes_pruned_worker_once() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let lastWrite = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in lastWrite })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "worker", transcriptPath: "/t/worker.jsonl"))
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "internal-recap"))
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["worker"])

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: "worker"), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "worker"))
    }

    func test_registry_tracked_stop_accepts_fresh_completed_transcript() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var lastWrite = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in lastWrite })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "worker", transcriptPath: "/t/worker.jsonl"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        lastWrite = now

        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: "worker"), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "worker"))
    }

    func test_registry_anonymous_tracked_stop_requires_a_live_worker() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let store = try makeRegistryStore(now: { now })
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: nil))
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "  \n"))

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "first"))
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "second"))
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: nil)?.entries.map(\.id), ["second"])
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: " "), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: nil), "a duplicate anonymous stop must not resume a completed parent")
    }

    func test_registry_retires_entries_whose_transcript_went_quiet() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "busy", transcriptPath: "/t/busy.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "quiet", transcriptPath: "/t/quiet.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "no-transcript"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "not-yet-written", transcriptPath: "/t/missing.jsonl"))
        modifiedAt["/t/busy.jsonl"] = now
        modifiedAt["/t/quiet.jsonl"] = now

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.map(\.id),
            ["busy", "no-transcript", "not-yet-written"],
            "only an existing transcript that stopped being written retires its entry"
        )

        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.map(\.id),
            ["busy"],
            "entries without a readable transcript still fall back to the stale window"
        )
    }

    func test_registry_quiet_transcript_retires_claude_but_not_codex() throws {
        // Codex's parent turn outlives its sub-threads and `clear` retires the
        // set; a sub-thread parked between turns keeps a quiet rollout file,
        // so only the stale window applies there.
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        let codexKey = AgentSubagentRegistryStore.Key(tool: "codex", worklaneID: paneKey.worklaneID, paneID: paneKey.paneID)
        XCTAssertTrue(paneKey.transcriptIsLivenessSignal)
        XCTAssertFalse(codexKey.transcriptIsLivenessSignal)

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "claude-child", transcriptPath: "/t/claude.jsonl"))
        try store.start(key: codexKey, entry: PaneAgentSubagentEntry(id: "codex-child", transcriptPath: "/t/rollout.jsonl"))

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty, "a quiet Claude transcript retires the entry")
        XCTAssertEqual(try store.summary(key: codexKey)?.entries.map(\.id), ["codex-child"], "a quiet Codex rollout is not a finish signal")

        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow)
        XCTAssertEqual(try store.summary(key: codexKey), .empty, "Codex entries still age out on the stale window")
    }

    func test_registry_fresh_re_registration_survives_stale_transcript_until_quiet_window() throws {
        // A child re-registered by its own hook is alive even when its
        // transcript has not been touched for a while (a long tool call); the
        // quiet window restarts from the re-registration, not the file mtime.
        var now = Date(timeIntervalSince1970: 10_000)
        let modifiedAt = now.addingTimeInterval(-(AgentSubagentRegistryStore.transcriptQuietWindow + 100))
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in modifiedAt })

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "abc", transcriptPath: "/t/abc.jsonl"))
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["abc"], "startedAt is newer than the quiet cutoff")

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["abc"])

        now = now.addingTimeInterval(2)
        let pruned = try XCTUnwrap(try store.prunedSummary(key: paneKey))
        XCTAssertEqual(pruned.summary, .empty, "once the registration itself is older than the window the quiet transcript wins")
        XCTAssertTrue(pruned.retired)
    }

    func test_registry_keeps_explicit_transcript_path_over_later_update() throws {
        let store = try makeRegistryStore()
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", transcriptPath: "/explicit/agent-a.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore", transcriptPath: "/derived/subagents/agent-a.jsonl"))
        let merged = try XCTUnwrap(try store.summary(key: paneKey)?.entries.first)
        XCTAssertEqual(merged.transcriptPath, "/explicit/agent-a.jsonl", "the first recorded path wins over a later derived one")
        XCTAssertEqual(merged.agentType, "Explore", "other facts still merge in")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", transcriptPath: "/late/agent-b.jsonl"))
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.first(where: { $0.id == "b" })?.transcriptPath,
            "/late/agent-b.jsonl",
            "a path arriving after a pathless start is still adopted"
        )
    }

    func test_registry_stop_with_guessed_id_falls_back_to_oldest() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try makeRegistryStore(now: { now })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "first"))
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "second"))

        let explicitMiss = try store.stop(key: paneKey, subagentID: "unknown")
        XCTAssertEqual(explicitMiss.count, 2, "an explicit id that misses is a no-op")

        let guessedMiss = try store.stop(key: paneKey, subagentID: "unknown", retireOldestWhenUnknown: true)
        XCTAssertEqual(guessedMiss.entries.map(\.id), ["second"], "a guessed id that misses retires the oldest")

        let guessedHit = try store.stop(key: paneKey, subagentID: "second", retireOldestWhenUnknown: true)
        XCTAssertEqual(guessedHit, .empty, "a guessed id that matches retires exactly that entry")
    }

    func test_registry_guessed_stop_for_pruned_id_does_not_retire_a_sibling() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "gone", transcriptPath: "/t/gone.jsonl"))
        modifiedAt["/t/gone.jsonl"] = now
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "busy", transcriptPath: "/t/busy.jsonl"))

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["busy"], "quiet transcript retired `gone`")

        let lateStop = try store.stop(key: paneKey, subagentID: "gone", retireOldestWhenUnknown: true)
        XCTAssertEqual(lateStop.entries.map(\.id), ["busy"], "a late stop for a pruned child must not take a sibling")

        let unknownStop = try store.stop(key: paneKey, subagentID: "never-seen", retireOldestWhenUnknown: true)
        XCTAssertEqual(unknownStop, .empty, "an id that was never pruned still falls back to the oldest")

        // A pruned child re-registering forgets its tombstone.
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "gone", transcriptPath: "/t/gone.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "other"))
        XCTAssertEqual(try store.stop(key: paneKey, subagentID: "gone", retireOldestWhenUnknown: true).entries.map(\.id), ["other"])
    }

    func test_registry_pruned_id_memory_is_bounded_and_cleared() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        let overflow = AgentSubagentRegistryStore.prunedIDMemory + 1
        for index in 0..<overflow {
            try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "old-\(index)", transcriptPath: "/t/\(index).jsonl"))
        }
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))

        // Exactly one of the pruned ids fell out of memory; the rest are tombstones.
        var retiredLive = 0
        for index in 0..<overflow {
            if try store.stop(key: paneKey, subagentID: "old-\(index)", retireOldestWhenUnknown: true).isEmpty {
                retiredLive += 1
                try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))
            }
        }
        XCTAssertEqual(retiredLive, 1)

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "fresh", transcriptPath: "/t/fresh.jsonl"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        _ = try store.summary(key: paneKey)
        _ = try store.clear(key: paneKey)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))
        XCTAssertEqual(try store.stop(key: paneKey, subagentID: "fresh", retireOldestWhenUnknown: true), .empty, "clear drops the tombstones too")
    }

    func test_attach_subagents_leaves_long_standing_empty_registry_untouched() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        let target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) = (nil, paneKey.worklaneID, paneKey.paneID)
        let running = [AgentEventBridge.lifecyclePayload(target: target, toolName: "Claude Code", state: .running)]

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a"))
        try store.stop(key: paneKey, subagentID: "a")
        let untouched = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertNil(untouched.first?.subagents, "an empty set that is not news stays off the payload")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", transcriptPath: "/t/b.jsonl"))
        modifiedAt["/t/b.jsonl"] = now
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let retired = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertEqual(retired.first?.subagents, .empty, "a set that just emptied travels explicitly")

        let again = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertNil(again.first?.subagents, "the next read is a long-standing empty again")
    }

    func test_default_store_resolves_away_from_application_support_under_xctest() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.standardizedFileURL.path
        let appSupport = try XCTUnwrap(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Zentty", isDirectory: true).standardizedFileURL.path

        let underTests = AgentSubagentRegistryStore(environment: ["XCTestConfigurationFilePath": "/x/config.xctestconfiguration"])
        XCTAssertTrue(underTests.stateURL.standardizedFileURL.path.hasPrefix(temporary), "\(underTests.stateURL.path)")
        XCTAssertTrue(underTests.stateURL.path.contains("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(fileManager.fileExists(atPath: underTests.stateURL.deletingLastPathComponent().path), "per-process directory is created")

        let inApp = AgentSubagentRegistryStore(environment: [:])
        XCTAssertEqual(inApp.stateURL.standardizedFileURL.path, appSupport + "/agent-subagent-sessions.json")

        let overridden = AgentSubagentRegistryStore(environment: [
            "XCTestConfigurationFilePath": "/x/config.xctestconfiguration",
            "ZENTTY_SUBAGENT_STATE_PATH": "/custom/registry.json",
        ])
        XCTAssertEqual(overridden.stateURL.path, "/custom/registry.json", "the explicit override still wins")

        // The real test process must be routed too, not just a stubbed one.
        XCTAssertTrue(AgentSubagentRegistryStore().stateURL.standardizedFileURL.path.hasPrefix(temporary))
    }

    // MARK: - Model resolver

    func test_claude_model_resolver_prefers_meta_sidecar_then_transcript() throws {
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        XCTAssertNil(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath))

        try """
        {"parentUuid":null,"isSidechain":true,"agentId":"abc","type":"user","message":{"role":"user","content":"hi"}}
        {"parentUuid":"x","isSidechain":true,"agentId":"abc","type":"assistant","message":{"model":"claude-opus-5","role":"assistant","content":[]}}
        """.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "claude-opus-5")

        try """
        {"agentType":"general-purpose","description":"x","toolUseId":"toolu_1","spawnDepth":1,"model":"sonnet"}
        """.write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "sonnet")

        // A fork inherits the parent's model; the sidecar says `inherit`, so
        // the transcript's real model wins.
        try """
        {"agentType":"fork","description":"x","toolUseId":"toolu_2","spawnDepth":2,"model":"inherit"}
        """.write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "claude-opus-5")
    }

    func test_claude_agent_transcript_path_derives_from_session_transcript() {
        XCTAssertEqual(
            AgentSubagentModelResolver.claudeAgentTranscriptPath(
                sessionTranscriptPath: "/Users/x/.claude/projects/p/session-1.jsonl",
                agentID: "a034fe"
            ),
            "/Users/x/.claude/projects/p/session-1/subagents/agent-a034fe.jsonl"
        )
        XCTAssertNil(AgentSubagentModelResolver.claudeAgentTranscriptPath(sessionTranscriptPath: nil, agentID: "a"))
    }

    func test_codex_thread_info_reads_nickname_role_and_model_from_rollout_head() {
        let rollout = """
        {"timestamp":"t","type":"session_meta","payload":{"id":"01a07132","parent_thread_id":"01a07119","source":{"subagent":{"thread_spawn":{"parent_thread_id":"01a07119","depth":1,"agent_path":"/root/unread_ui","agent_nickname":"Dirac","agent_role":"worker"}}},"thread_source":"subagent"}}
        {"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[]}}
        {"timestamp":"t","type":"turn_context","payload":{"turn_id":"1","cwd":"/tmp","model":"gpt-6-astra","effort":"medium"}}
        """
        let info = AgentSubagentModelResolver.codexThreadInfo(rolloutText: rollout)
        XCTAssertEqual(info, .init(model: "gpt-6-astra", nickname: "Dirac", role: "worker"))

        let guardian = """
        {"timestamp":"t","type":"session_meta","payload":{"id":"x","parent_thread_id":"y","source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review"}}
        {"timestamp":"t","type":"turn_context","payload":{"model":"codex-auto-review"}}
        """
        XCTAssertEqual(AgentSubagentModelResolver.codexThreadInfo(rolloutText: guardian), .init(model: "codex-auto-review", nickname: nil, role: nil))
        XCTAssertNil(AgentSubagentModelResolver.codexThreadInfo(rolloutText: "not json"))
    }

    // MARK: - Claude adapter

    func test_claude_subagent_start_and_stop_update_payload_subagents() throws {
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        try #"{"agentType":"general-purpose","model":"opus"}"#
            .write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()

        let started = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"general-purpose","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let startPayload = try XCTUnwrap(started.first)
        XCTAssertEqual(startPayload.state, .running)
        XCTAssertEqual(startPayload.sessionID, "session-1")
        XCTAssertEqual(startPayload.subagents?.count, 1)
        XCTAssertEqual(startPayload.subagents?.entries.first?.model, "opus")
        XCTAssertEqual(startPayload.subagents?.entries.first?.agentType, "general-purpose")

        let stopped = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"abc","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stopPayload = try XCTUnwrap(stopped.first)
        XCTAssertEqual(stopPayload.state, .running, "parent keeps working after a subagent finishes")
        XCTAssertEqual(stopPayload.subagents, .empty)
    }

    func test_claude_hooks_inside_subagent_fill_in_model_from_transcript() throws {
        // Live Claude 2.1.261 payloads: SubagentStart carries the session
        // transcript_path and agent_id but no agent_transcript_path, so the
        // subagent transcript is derived as <session>/subagents/agent-<id>.jsonl.
        let directory = try makeTemporaryDirectory()
        let sessionTranscriptPath = directory.appendingPathComponent("session-1.jsonl").path
        let subagentsDirectory = directory.appendingPathComponent("session-1/subagents")
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        let transcriptPath = subagentsDirectory.appendingPathComponent("agent-abc.jsonl").path
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()

        let started = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","transcript_path":"\#(sessionTranscriptPath)","agent_id":"abc","agent_type":"Explore"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(started.first?.subagents?.entries.first?.model, "transcript does not exist yet at spawn")
        XCTAssertEqual(started.first?.subagents?.entries.first?.transcriptPath, transcriptPath)

        try #"{"type":"assistant","message":{"model":"claude-sonnet-5","role":"assistant"}}"#
            .write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        let toolUse = try claudePayloads(
            #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_name":"Read","agent_id":"abc","agent_type":"Explore"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(toolUse.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.subagents?.entries.first?.model, "claude-sonnet-5")
        XCTAssertEqual(payload.subagents?.entries.first?.modelLabel, "sonnet")
    }

    func test_claude_stop_keeps_async_subagents_alive() throws {
        // Claude Code launches Agent tool calls asynchronously: the parent ends
        // its turn (Stop) while the subagents keep running and re-wakes on a
        // task notification. Stop must therefore carry the live set, not blank it.
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        for id in ["a1", "a2", "a3"] {
            _ = try claudePayloads(
                #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"\#(id)","agent_type":"general-purpose"}"#,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }

        let stopped = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stopPayload = try XCTUnwrap(stopped.first)
        XCTAssertEqual(stopPayload.state, .idle)
        XCTAssertEqual(stopPayload.subagents?.count, 3, "parent going idle must not blank running subagents")

        let idlePrompt = try claudePayloads(
            #"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"session-1","message":"Claude is waiting for your input"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(idlePrompt.first?.subagents?.count, 3, "idle prompt must not blank running subagents")

        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"a2","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stoppedAgain = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedAgain.first?.subagents?.entries.map(\.id), ["a1", "a3"])

        for id in ["a1", "a3"] {
            _ = try claudePayloads(
                #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"\#(id)"}"#,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }
        let finalStop = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(finalStop.first?.subagents, .empty, "explicit empty once every subagent stopped")
    }

    func test_claude_stop_without_recorded_subagents_leaves_payload_untouched() throws {
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        let stopped = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(stopped.first?.subagents)
    }

    func test_claude_nested_fork_tracks_distinct_ids() throws {
        // A subagent spawning its own forks fires SubagentStart/Stop with the
        // child's agent_id from inside the enclosing subagent.
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"outer","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let nestedStart = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"inner","agent_type":"fork"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(nestedStart.first?.subagents?.entries.map(\.id), ["inner", "outer"])

        let nestedStop = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"inner","agent_type":"fork"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(nestedStop.first?.subagents?.entries.map(\.id), ["outer"])
    }

    func test_claude_hook_inside_subagent_re_registers_a_retired_child() throws {
        // Liveness pruning can retire a child that sat in a long tool call. Its
        // next hook (which carries agent_id) puts it back.
        let sessionStore = try makeClaudeSessionStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        try "{}".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        var transcriptModifiedAt = now
        let subagentStore = try makeRegistryStore(
            now: { now },
            transcriptModificationDate: { _ in transcriptModifiedAt }
        )

        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let parentHook = try claudePayloads(
            #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_name":"Bash"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(parentHook.first?.subagents, .empty, "retirement must reach the reducer as an explicit empty set")
        XCTAssertEqual(try subagentStore.summary(key: paneKey), .empty, "quiet transcript retires the entry")

        transcriptModifiedAt = now
        let toolUse = try claudePayloads(
            #"{"hook_event_name":"PostToolUse","session_id":"session-1","tool_name":"Bash","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(toolUse.first?.subagents?.entries.map(\.id), ["abc"])
        XCTAssertEqual(toolUse.first?.subagents?.entries.first?.agentType, "Explore")
    }

    func test_claude_unrelated_hook_leaves_subagents_untouched_when_none_recorded() throws {
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        let payloads = try claudePayloads(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(payloads.first?.subagents)
    }

    // MARK: - Codex adapter

    func test_codex_subagent_start_attributes_to_root_session_and_reads_rollout() throws {
        let directory = try makeTemporaryDirectory()
        let rolloutPath = directory.appendingPathComponent("rollout-2026-09-05T12-52-37-01a07132-eb9a-7222-ad53-819ccda4db3c.jsonl").path
        try """
        {"type":"session_meta","payload":{"id":"01a07132-eb9a-7222-ad53-819ccda4db3c","parent_thread_id":"root","source":{"subagent":{"thread_spawn":{"agent_nickname":"Noether","agent_role":"default"}}}}}
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        """.write(toFile: rolloutPath, atomically: true, encoding: .utf8)
        let subagentStore = try makeRegistryStore()

        _ = try codexPayloads(#"{"hook_event_name":"SessionStart","session_id":"root"}"#, subagentStore: subagentStore)
        // Codex sends the thread id on start but the rollout path only on stop;
        // both must resolve to the same registry entry.
        let started = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child-thread","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c","agent_type":"worker","model":"gpt-5.6-sol"}"#,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(started.first)
        XCTAssertEqual(payload.sessionID, "root")
        XCTAssertEqual(payload.state, .running)
        let entry = try XCTUnwrap(payload.subagents?.entries.first)
        XCTAssertEqual(entry.id, "01a07132-eb9a-7222-ad53-819ccda4db3c")
        XCTAssertEqual(entry.model, "gpt-5.6-sol", "payload model is used until the rollout exists")
        XCTAssertNil(entry.nickname)

        let toolHook = try codexPayloads(
            #"{"hook_event_name":"PostToolUse","session_id":"root","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(toolHook.first?.subagents?.entries.first?.model, "gpt-5.6-sol")

        let stoppedWithPath = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child-thread","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedWithPath.first?.subagents, .empty)

        let restarted = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child-thread","agent_type":"worker","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        let entryFromRollout = try XCTUnwrap(restarted.first?.subagents?.entries.first)
        XCTAssertEqual(entryFromRollout.id, "01a07132-eb9a-7222-ad53-819ccda4db3c")
        XCTAssertEqual(entryFromRollout.model, "gpt-5.6-sol")
        XCTAssertEqual(entryFromRollout.nickname, "Noether")
        XCTAssertEqual(entryFromRollout.agentType, "worker")

        let childStop = try codexPayloads(#"{"hook_event_name":"Stop","session_id":"child-thread"}"#, subagentStore: subagentStore)
        XCTAssertNil(childStop.first?.subagents, "a sub-thread Stop must not blank the parent's badge")

        let stopped = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child-thread","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)

        let rootStop = try codexPayloads(#"{"hook_event_name":"Stop","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(rootStop.first?.subagents, .empty)
    }

    func test_codex_positional_subagent_events_map_like_named_hooks() throws {
        let subagentStore = try makeRegistryStore()
        let payloads = try AgentEventBridge.codexAdapter(
            data: Data(#"{"session_id":"root","agent_type":"worker"}"#.utf8),
            defaultEventName: "subagent-start",
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(payloads.first?.subagents?.count, 1)
    }

    func test_codex_tool_hook_resolves_model_once_rollout_exists() throws {
        let directory = try makeTemporaryDirectory()
        let rolloutPath = directory.appendingPathComponent("rollout-x.jsonl").path
        let subagentStore = try makeRegistryStore()
        _ = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"root","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        try #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#.write(toFile: rolloutPath, atomically: true, encoding: .utf8)
        let payloads = try codexPayloads(#"{"hook_event_name":"PostToolUse","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(payloads.first?.subagents?.entries.first?.modelLabel, "astra")
    }

    func test_codex_quiet_rollout_keeps_subagent_until_stop() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let subagentStore = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        _ = try codexPayloads(#"{"hook_event_name":"SessionStart","session_id":"root"}"#, subagentStore: subagentStore)
        _ = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child","agent_id":"thread-1","agent_transcript_path":"/t/rollout-thread-1.jsonl"}"#,
            subagentStore: subagentStore
        )

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let toolHook = try codexPayloads(#"{"hook_event_name":"PostToolUse","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(toolHook.first?.subagents?.entries.map(\.id), ["thread-1"], "a quiet rollout does not retire a Codex sub-thread")

        let stopped = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child","agent_id":"thread-1"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)
    }

    // MARK: - Grok adapter

    func test_grok_subagent_hooks_track_count() throws {
        let subagentStore = try makeRegistryStore()
        let started = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"sub-1","agent_type":"explore"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(started.first?.state, .running)
        XCTAssertEqual(started.first?.subagents?.entries.first?.agentType, "explore")

        let stopped = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"sub-1"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)
    }

    func test_grok_stop_keeps_background_subagents_and_derives_child_transcript() throws {
        // spawn_subagent runs in the background by default: the parent's
        // `stop` fires while the child is still working.
        let subagentStore = try makeRegistryStore()
        let started = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-1","subagentType":"explore","transcriptPath":"/Users/me/.grok/sessions/cwd/parent/updates.jsonl"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(
            started.first?.subagents?.entries.first?.transcriptPath,
            "/Users/me/.grok/sessions/cwd/child-1/updates.jsonl"
        )

        let stopped = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"Stop","sessionId":"parent"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.state, .idle)
        XCTAssertEqual(stopped.first?.subagents?.entries.map(\.id), ["child-1"])

        _ = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStop","sessionId":"child-1","subagentId":"child-1"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        let stoppedAgain = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"Stop","sessionId":"parent"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedAgain.first?.subagents, .empty)
        XCTAssertNil(AgentEventBridge.grokSubagentTranscriptPath(parentTranscriptPath: nil, subagentID: "x"))
        XCTAssertNil(AgentEventBridge.grokSubagentTranscriptPath(parentTranscriptPath: "/updates.jsonl", subagentID: "x"))
    }

    func test_grok_subagent_stop_by_session_id_falls_back_to_oldest_child() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let subagentStore = try makeRegistryStore(now: { now })
        func grok(_ json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.grokAdapter(data: Data(json.utf8), environment: environment, subagentStore: subagentStore)
        }
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-1"}"#)
        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-2"}"#)

        // The stop hook runs in the child's context: its session id is the child.
        let byChildSession = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"child-2"}"#)
        XCTAssertEqual(byChildSession.first?.subagents?.entries.map(\.id), ["child-1"])

        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-3"}"#)

        // A session id that matches nothing was only a guess: retire the oldest.
        let byUnknownSession = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"parent"}"#)
        XCTAssertEqual(byUnknownSession.first?.subagents?.entries.map(\.id), ["child-3"])

        // An explicit subagent id that misses stays a no-op.
        let byUnknownExplicit = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"parent","subagentId":"never-started"}"#)
        XCTAssertEqual(byUnknownExplicit.first?.subagents?.entries.map(\.id), ["child-3"])
    }

    func test_grok_late_stop_from_pruned_child_leaves_siblings_alone() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var modifiedAt: [String: Date] = [:]
        let subagentStore = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        func grok(_ json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.grokAdapter(data: Data(json.utf8), environment: environment, subagentStore: subagentStore)
        }
        let parentTranscript = "/Users/me/.grok/sessions/cwd/parent/updates.jsonl"
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"A","transcriptPath":"\#(parentTranscript)"}"#)
        modifiedAt["/Users/me/.grok/sessions/cwd/A/updates.jsonl"] = now
        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"B","transcriptPath":"\#(parentTranscript)"}"#)

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/Users/me/.grok/sessions/cwd/B/updates.jsonl"] = now
        let pruned = try grok(#"{"hook_event_name":"Stop","sessionId":"parent"}"#)
        XCTAssertEqual(pruned.first?.subagents?.entries.map(\.id), ["B"], "A's quiet transcript retired it")

        // A's stop hook arrives late, carrying only its session id.
        let lateStop = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"A"}"#)
        XCTAssertEqual(lateStop.first?.subagents?.entries.map(\.id), ["B"], "a late stop for a pruned child must not retire B")
        XCTAssertEqual(lateStop.first?.subagents?.count, 1)
    }

    func test_grok_hooks_installer_registers_subagent_events_without_matcher() {
        XCTAssertTrue(GrokHooksInstaller.defaultManagedEvents.contains("SubagentStart"))
        XCTAssertTrue(GrokHooksInstaller.defaultManagedEvents.contains("SubagentStop"))
    }

    // MARK: - Reducer

    func test_reducer_carries_subagents_until_explicitly_cleared() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])

        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(claudePayload(state: .running, subagents: nil), now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))?.subagents, summary)

        reducerState.apply(claudePayload(state: .idle, subagents: .empty), now: startedAt.addingTimeInterval(2))
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))?.subagents, .empty)
    }

    func test_reducer_keeps_idle_session_visible_while_subagents_run() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])

        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: startedAt.addingTimeInterval(1))

        let afterIdleWindow = startedAt.addingTimeInterval(1 + PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterIdleWindow, isProcessAlive: { _ in true })
        let status = reducerState.reducedStatus(now: afterIdleWindow)
        XCTAssertEqual(status?.state, .idle, "idle parent stays visible while background subagents run")
        XCTAssertEqual(status?.subagents, summary)

        reducerState.apply(claudePayload(state: .idle, subagents: .empty), now: afterIdleWindow)
        let afterSecondWindow = afterIdleWindow.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterSecondWindow, isProcessAlive: { _ in true })
        XCTAssertNil(reducerState.reducedStatus(now: afterSecondWindow), "normal idle expiry resumes once the subagents retire")
    }

    func test_reducer_subagent_snapshot_expires_without_fresh_hooks() {
        // Registry pruning only runs when a hook arrives, not on a timer. If
        // none fire (the children died, the pane was left alone), the reducer's
        // snapshot must not pin the idle parent forever: it ages out on the
        // registry's own quiet window.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        let insideWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        reducerState.sweep(now: insideWindow, isProcessAlive: { _ in true })
        XCTAssertEqual(reducerState.reducedStatus(now: insideWindow)?.subagents, summary, "still live inside the quiet window")

        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        // Shell activity bumps `updatedAt` but is not a hook: it must not
        // re-arm the badge.
        reducerState.apply(shellPayload(.promptIdle), now: pastWindow)
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "an unrefreshed snapshot no longer counts as live")
        reducerState.sweep(now: pastWindow, isProcessAlive: { _ in true })
        XCTAssertTrue(reducerState.sessionsByID.isEmpty, "sweep retires the idle parent once the snapshot expired")
    }

    func test_reducer_subagent_snapshot_clock_is_the_last_hook_not_the_last_signal() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        // Shell signals keep arriving right up to the window's edge...
        let lastShell = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        reducerState.apply(shellPayload(.promptIdle), now: lastShell)
        XCTAssertEqual(reducerState.reducedStatus(now: lastShell)?.subagents, summary)

        // ...and still do not stretch the badge past it.
        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "only a payload carrying subagents refreshes the cap")

        // A hook carrying the set does.
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: pastWindow)
        XCTAssertEqual(reducerState.reducedStatus(now: pastWindow.addingTimeInterval(1))?.subagents, summary)
    }

    func test_reducer_subagent_snapshot_expires_with_tracked_pid_alive() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Claude Code",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(0.5)
        )
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        let afterIdleWindow = idleAt.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterIdleWindow, isProcessAlive: { _ in true })
        let visible = reducerState.reducedStatus(now: afterIdleWindow)
        XCTAssertEqual(visible?.state, .idle)
        XCTAssertEqual(visible?.trackedPID, 4242)
        XCTAssertEqual(visible?.subagents, summary)

        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        reducerState.apply(shellPayload(.promptIdle), now: pastWindow)
        reducerState.sweep(now: pastWindow, isProcessAlive: { _ in true })
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "the badge cannot keep an idle pane visible past the quiet window")
        XCTAssertEqual(reducerState.sessionsByID.count, 1, "the live process keeps the session itself around")
    }

    // MARK: - Helpers

    private func claudePayload(state: PaneAgentState, subagents: PaneAgentSubagentSummary?) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-shell"),
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            confidence: .explicit,
            sessionID: "session-1",
            subagents: subagents,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func shellPayload(_ shellActivityState: PaneShellActivityState) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-shell"),
            signalKind: .shellState,
            state: nil,
            shellActivityState: shellActivityState,
            origin: .shell,
            toolName: "Claude Code",
            text: nil,
            sessionID: "session-1",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func claudePayloads(
        _ json: String,
        sessionStore: ClaudeHookSessionStore,
        subagentStore: AgentSubagentRegistryStore
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(json.utf8)),
            environment: environment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
    }

    private func codexPayloads(_ json: String, subagentStore: AgentSubagentRegistryStore) throws -> [AgentStatusPayload] {
        try AgentEventBridge.codexAdapter(
            data: Data(json.utf8),
            defaultEventName: nil,
            environment: environment,
            subagentStore: subagentStore
        )
    }

    private func makeClaudeSessionStore() throws -> ClaudeHookSessionStore {
        let store = ClaudeHookSessionStore(stateURL: try makeTemporaryDirectory().appendingPathComponent("claude-hook-sessions.json"))
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )
        return store
    }

    private func makeRegistryStore(
        now: @escaping () -> Date = Date.init,
        transcriptModificationDate: ((String) -> Date?)? = nil
    ) throws -> AgentSubagentRegistryStore {
        let stateURL = try makeTemporaryDirectory().appendingPathComponent("agent-subagent-sessions.json")
        if let transcriptModificationDate {
            return AgentSubagentRegistryStore(stateURL: stateURL, now: now, transcriptModificationDate: transcriptModificationDate)
        }
        // Tests that do not care about liveness treat every transcript as alive.
        return AgentSubagentRegistryStore(stateURL: stateURL, now: now, transcriptModificationDate: { _ in nil })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-subagent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
