import Darwin
import Foundation
import os

private let subagentRegistryLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgentSubagentRegistry")

/// File-backed registry of live subagents per pane, shared by the Claude,
/// Codex, and Grok hook adapters.
///
/// Hook invocations are short-lived processes, so the set of running
/// subagents has to survive between `SubagentStart` and `SubagentStop`. The
/// registry is keyed by pane (tool + worklane + pane) rather than by session
/// id because Codex sub-threads report their own thread ids, and only the
/// pane is stable across parent and child hooks.
///
/// The parent's turn ending is *not* a retirement signal: Claude Code runs
/// Agent tool calls asynchronously, so the parent routinely goes idle with
/// subagents still working. Entries leave the registry on `SubagentStop`, or
/// when their transcript on disk stops being written (liveness pruning), or
/// after `staleEntryWindow` as a last resort.
final class AgentSubagentRegistryStore {
    struct Key: Equatable {
        let tool: String
        let worklaneID: WorklaneID
        let paneID: PaneID

        var rawValue: String {
            "\(tool)|\(worklaneID.rawValue)|\(paneID.rawValue)"
        }
    }

    /// Entries older than this are dropped on read: a `SubagentStop` that never
    /// arrived should not pin a badge to the sidebar forever. Only reached by
    /// entries whose transcript cannot be observed.
    static let staleEntryWindow: TimeInterval = 6 * 60 * 60

    /// An entry whose transcript exists but has not been written for this long
    /// is treated as finished. A child parked in a long tool call can trip
    /// this; its next hook re-registers it.
    static let transcriptQuietWindow: TimeInterval = 15 * 60

    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    /// Last write time of a subagent transcript, `nil` when it does not exist
    /// (or cannot be read), in which case the entry is kept.
    private let transcriptModificationDate: (String) -> Date?

    init(
        stateURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        transcriptModificationDate: ((String) -> Date?)? = nil
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.now = now
        self.transcriptModificationDate = transcriptModificationDate ?? { path in
            (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        self.encoder.outputFormatting = [.sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        let env = processInfo.environment
        if let overridePath = env["ZENTTY_SUBAGENT_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("agent-subagent-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-agent-subagent-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    // MARK: - Root session

    /// Remember the parent session id for a pane so subagent payloads can be
    /// attributed to it even when the hook carries a child thread id.
    func recordRootSession(key: Key, sessionID: String?) throws {
        guard let sessionID = normalizedOptional(sessionID) else { return }
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            entry.rootSessionID = sessionID
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
        }
    }

    func rootSessionID(key: Key) throws -> String? {
        try withLockedState { state in
            state.panes[key.rawValue]?.rootSessionID
        }
    }

    // MARK: - Subagents

    /// Record a running subagent. Re-running for a known id merges the new
    /// facts (model, transcript) and keeps the original start time; running it
    /// for an id that liveness pruning already retired simply re-registers it.
    @discardableResult
    func start(key: Key, entry subagent: PaneAgentSubagentEntry) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            prune(&entry, key: key)
            let existing = entry.subagentsByID[subagent.id]
            entry.subagentsByID[subagent.id] = SubagentRecord(
                entry: Self.merged(existing?.entry, with: subagent),
                startedAt: existing?.startedAt ?? now().timeIntervalSince1970
            )
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent \(existing == nil ? "start" : "update", privacy: .public) key=\(key.rawValue, privacy: .public) id=\(subagent.id, privacy: .public) type=\(subagent.agentType ?? "-", privacy: .public) count=\(entry.subagentsByID.count, privacy: .public)"
            )
            return entry.summary
        }
    }

    @discardableResult
    func stop(key: Key, subagentID: String?) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            prune(&entry, key: key)
            var removedID: String?
            if let subagentID = normalizedOptional(subagentID) {
                removedID = entry.subagentsByID.removeValue(forKey: subagentID) == nil ? nil : subagentID
            } else if let oldest = entry.subagentsByID.min(by: { $0.value.startedAt < $1.value.startedAt }) {
                // No id on the stop hook: retire the longest-running subagent.
                entry.subagentsByID.removeValue(forKey: oldest.key)
                removedID = oldest.key
            }
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent stop key=\(key.rawValue, privacy: .public) id=\(subagentID ?? "-", privacy: .public) removed=\(removedID ?? "none", privacy: .public) count=\(entry.subagentsByID.count, privacy: .public)"
            )
            return entry.summary
        }
    }

    /// Current snapshot, or `nil` when nothing was ever recorded for the pane
    /// so callers can leave the payload field untouched.
    func summary(key: Key) throws -> PaneAgentSubagentSummary? {
        try prunedSummary(key: key)?.summary
    }

    /// Like `summary(key:)`, also reporting whether this read retired anything,
    /// so callers can tell a fresh "now empty" from a long-standing one.
    func prunedSummary(key: Key) throws -> (summary: PaneAgentSubagentSummary, retired: Bool)? {
        try withLockedState { state in
            guard var entry = state.panes[key.rawValue] else { return nil }
            let retired = prune(&entry, key: key)
            if retired {
                state.panes[key.rawValue] = entry
            }
            return (entry.summary, retired)
        }
    }

    /// Fill in models (and nicknames) that were unknown at start time. The
    /// resolver runs only for entries still missing a model, so this stays
    /// cheap to call from every hook.
    @discardableResult
    func refreshMissingModels(
        key: Key,
        resolver: (PaneAgentSubagentEntry) -> PaneAgentSubagentEntry?
    ) throws -> PaneAgentSubagentSummary? {
        try withLockedState { state in
            guard var entry = state.panes[key.rawValue], !entry.subagentsByID.isEmpty else { return nil }
            var changed = false
            for (id, record) in entry.subagentsByID where record.entry.model == nil {
                guard let resolved = resolver(record.entry), resolved.model != nil else { continue }
                entry.subagentsByID[id] = SubagentRecord(
                    entry: Self.merged(record.entry, with: resolved),
                    startedAt: record.startedAt
                )
                changed = true
            }
            if changed {
                entry.updatedAt = now().timeIntervalSince1970
                state.panes[key.rawValue] = entry
            }
            return entry.summary
        }
    }

    /// Drop every subagent for the pane and return the explicit empty summary
    /// to broadcast. Only for tools whose parent turn provably outlives every
    /// subagent; Claude's does not (see the type comment).
    @discardableResult
    func clear(key: Key) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            let dropped = entry.subagentsByID.count
            entry.subagentsByID.removeAll()
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent clear key=\(key.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
            )
            return .empty
        }
    }

    /// Forget the pane entirely (session ended).
    func remove(key: Key) throws {
        try withLockedState { state in
            let dropped = state.panes[key.rawValue]?.subagentsByID.count ?? 0
            state.panes.removeValue(forKey: key.rawValue)
            subagentRegistryLogger.info(
                "subagent remove key=\(key.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    /// Retire entries that are provably finished (transcript exists and went
    /// quiet) or hopelessly old. Returns whether anything changed.
    @discardableResult
    private func prune(_ entry: inout PaneEntry, key: Key) -> Bool {
        let current = now().timeIntervalSince1970
        let staleCutoff = current - Self.staleEntryWindow
        let quietCutoff = current - Self.transcriptQuietWindow
        var retired: [(id: String, reason: String)] = []
        for (id, record) in entry.subagentsByID {
            if let path = record.entry.transcriptPath, let modifiedAt = transcriptModificationDate(path) {
                // Observable transcript: it being written is the liveness signal.
                if modifiedAt.timeIntervalSince1970 < quietCutoff, record.startedAt < quietCutoff {
                    retired.append((id, "quiet-transcript"))
                }
            } else if record.startedAt < staleCutoff {
                retired.append((id, "stale"))
            }
        }
        guard !retired.isEmpty else { return false }
        for item in retired {
            entry.subagentsByID.removeValue(forKey: item.id)
            let remaining = entry.subagentsByID.count
            subagentRegistryLogger.info(
                "subagent retire key=\(key.rawValue, privacy: .public) id=\(item.id, privacy: .public) reason=\(item.reason, privacy: .public) count=\(remaining, privacy: .public)"
            )
        }
        return true
    }

    // MARK: - Internals

    private struct SubagentRecord: Codable {
        var entry: PaneAgentSubagentEntry
        var startedAt: TimeInterval
    }

    private struct PaneEntry: Codable {
        var rootSessionID: String?
        var subagentsByID: [String: SubagentRecord] = [:]
        var updatedAt: TimeInterval = 0

        var summary: PaneAgentSubagentSummary {
            PaneAgentSubagentSummary(entries: subagentsByID.values.map(\.entry))
        }
    }

    private struct StoreFile: Codable {
        var version: Int = 1
        var panes: [String: PaneEntry] = [:]
    }

    private static func merged(_ existing: PaneAgentSubagentEntry?, with update: PaneAgentSubagentEntry) -> PaneAgentSubagentEntry {
        PaneAgentSubagentEntry(
            id: update.id,
            agentType: update.agentType ?? existing?.agentType,
            model: update.model ?? existing?.model,
            nickname: update.nickname ?? existing?.nickname,
            transcriptPath: update.transcriptPath ?? existing?.transcriptPath
        )
    }

    private func withLockedState<T>(_ body: (inout StoreFile) throws -> T) throws -> T {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { flock(descriptor, LOCK_UN) }

        var state = loadState()
        let result = try body(&state)
        try saveState(state)
        return result
    }

    private func loadState() -> StoreFile {
        guard let data = try? Data(contentsOf: stateURL) else {
            return StoreFile()
        }
        return (try? decoder.decode(StoreFile.self, from: data)) ?? StoreFile()
    }

    private func saveState(_ state: StoreFile) throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
