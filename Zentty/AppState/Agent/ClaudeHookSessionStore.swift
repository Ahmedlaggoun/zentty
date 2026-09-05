import Darwin
import Foundation
import os

private let claudeHookSessionStoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "ClaudeHookSessionStore")

struct ClaudeHookSessionRecord: Codable, Equatable {
    let sessionID: String
    var windowIDRawValue: String?
    var worklaneIDRawValue: String
    var paneIDRawValue: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int32?
    var lastHumanMessage: String?
    var lastInteractionKindRawValue: String?
    var lastStructuredInteractionText: String?
    var lastStructuredInteractionKindRawValue: String?
    var lastStructuredInteractionConfidenceRawValue: String?
    /// `tool_use_id` of the tool call whose PermissionRequest /
    /// AskUserQuestion prompt is currently open. Lets PostToolUse for a
    /// sibling tool in the same batch leave the open prompt alone.
    var lastStructuredInteractionToolUseID: String? = nil
    /// `tool_name` of that same open prompt. Claude Code's PermissionRequest
    /// payload carries no `tool_use_id`, so when the id could not be inherited
    /// from the preceding PreToolUse this is the only way to tell a sibling
    /// tool's PostToolUse apart from the prompted tool's own completion.
    var lastStructuredInteractionToolName: String? = nil
    /// `agent_id` of the hook that opened that prompt (`nil` for the parent).
    /// A PostToolUse from a different agent context is a sibling and must
    /// leave the prompt alone.
    var lastStructuredInteractionAgentID: String? = nil
    /// Unclaimed PreToolUse announcements per agent context (Bash/Write/Edit
    /// matcher set), oldest first, keyed by `agent_id` with `""` for the
    /// parent. A PermissionRequest for the same tool in the same context
    /// inherits the oldest matching `tool_use_id` and consumes only that
    /// entry: an allowlisted sibling announced right after the prompted call
    /// must not hand its id to the prompt. Reset when the turn ends.
    var preToolUseSlotsByAgentID: [String: [ClaudePreToolUseSlot]] = [:]
    var lastNotificationText: String?
    var tasksByID: [String: Bool] = [:]
    var updatedAt: TimeInterval

    var windowID: WindowID? {
        windowIDRawValue.map(WindowID.init)
    }

    var worklaneID: WorklaneID {
        WorklaneID(worklaneIDRawValue)
    }

    var paneID: PaneID {
        PaneID(paneIDRawValue)
    }

    var lastInteractionKind: PaneAgentInteractionKind? {
        get { lastInteractionKindRawValue.flatMap(PaneAgentInteractionKind.init(rawValue:)) }
        set { lastInteractionKindRawValue = newValue?.rawValue }
    }

    var structuredInteractionText: String? {
        get { lastStructuredInteractionText ?? lastHumanMessage }
        set {
            lastStructuredInteractionText = newValue
            lastHumanMessage = newValue
        }
    }

    var structuredInteractionKind: PaneAgentInteractionKind? {
        get {
            lastStructuredInteractionKindRawValue
                .flatMap(PaneAgentInteractionKind.init(rawValue:))
                ?? lastInteractionKind
        }
        set {
            lastStructuredInteractionKindRawValue = newValue?.rawValue
            lastInteractionKind = newValue
        }
    }

    var structuredInteractionConfidence: AgentSignalConfidence? {
        get { lastStructuredInteractionConfidenceRawValue.flatMap(AgentSignalConfidence.init(rawValue:)) }
        set { lastStructuredInteractionConfidenceRawValue = newValue?.rawValue }
    }

    static func preToolUseSlotKey(agentID: String?) -> String {
        agentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func preToolUseSlots(agentID: String?) -> [ClaudePreToolUseSlot] {
        preToolUseSlotsByAgentID[Self.preToolUseSlotKey(agentID: agentID)] ?? []
    }
}

/// The tool call a PreToolUse announced, kept until the PermissionRequest
/// that may follow claims it.
struct ClaudePreToolUseSlot: Codable, Equatable {
    /// Announcements per agent context beyond this are not recorded: the
    /// prompt inherits the oldest matching entry, so it is the newest that
    /// must give way, and a burst of allowlisted calls must not grow the
    /// record forever.
    static let maximumPerAgent = 16

    var toolUseID: String
    var toolName: String?
}

extension ClaudeHookSessionRecord {
    private enum CodingKeys: String, CodingKey {
        case sessionID
        case windowIDRawValue
        case worklaneIDRawValue
        case paneIDRawValue
        case cwd
        case transcriptPath
        case pid
        case lastHumanMessage
        case lastInteractionKindRawValue
        case lastStructuredInteractionText
        case lastStructuredInteractionKindRawValue
        case lastStructuredInteractionConfidenceRawValue
        case lastStructuredInteractionToolUseID
        case lastStructuredInteractionToolName
        case lastStructuredInteractionAgentID
        case preToolUseSlotsByAgentID
        case lastNotificationText
        case tasksByID
        case updatedAt
    }

    /// Records written by an older build lack the newer keys. Synthesized
    /// decoding would throw on those, `loadState` would fall back to an empty
    /// file and the next save would wipe every live session, so every field
    /// added after the first release decodes as optional here.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        windowIDRawValue = try container.decodeIfPresent(String.self, forKey: .windowIDRawValue)
        worklaneIDRawValue = try container.decode(String.self, forKey: .worklaneIDRawValue)
        paneIDRawValue = try container.decode(String.self, forKey: .paneIDRawValue)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        lastHumanMessage = try container.decodeIfPresent(String.self, forKey: .lastHumanMessage)
        lastInteractionKindRawValue = try container.decodeIfPresent(String.self, forKey: .lastInteractionKindRawValue)
        lastStructuredInteractionText = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionText)
        lastStructuredInteractionKindRawValue = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionKindRawValue)
        lastStructuredInteractionConfidenceRawValue = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionConfidenceRawValue)
        lastStructuredInteractionToolUseID = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionToolUseID)
        lastStructuredInteractionToolName = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionToolName)
        lastStructuredInteractionAgentID = try container.decodeIfPresent(String.self, forKey: .lastStructuredInteractionAgentID)
        do {
            preToolUseSlotsByAgentID = try container.decodeIfPresent([String: [ClaudePreToolUseSlot]].self, forKey: .preToolUseSlotsByAgentID) ?? [:]
        } catch {
            // A malformed slot map only loses in-flight PreToolUse bookkeeping;
            // keep the rest of the record but leave a trace of what was dropped.
            let sessionID = self.sessionID
            let description = String(describing: error)
            claudeHookSessionStoreLogger.warning("Dropping malformed preToolUseSlotsByAgentID for session \(sessionID, privacy: .public): \(description, privacy: .public)")
            preToolUseSlotsByAgentID = [:]
        }
        lastNotificationText = try container.decodeIfPresent(String.self, forKey: .lastNotificationText)
        tasksByID = try container.decodeIfPresent([String: Bool].self, forKey: .tasksByID) ?? [:]
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
    }
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

final class ClaudeHookSessionStore {
    /// Where the session store lives; exposed so tests can check the resolution.
    let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        stateURL: URL,
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        self.init(environment: processInfo.environment, fileManager: fileManager)
    }

    convenience init(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        if let overridePath = environment["ZENTTY_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        // Under XCTest (same detection as main.swift) the default store must
        // never touch the real session file: tests that build the store or
        // call the Claude adapter without injecting a `stateURL` would
        // otherwise write fixture sessions into ~/Library/Application Support
        // and, on a decode failure, rewrite the live file empty. One file per
        // test process keeps parallel runners apart.
        if environment["XCTestConfigurationFilePath"] != nil {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.init(stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-claude-hook-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    func lookup(sessionID: String) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state in
            state.sessions[normalized(sessionID)]
        }
    }

    func upsert(
        sessionID: String,
        windowID: WindowID? = nil,
        worklaneID: WorklaneID,
        paneID: PaneID,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int32?,
        lastHumanMessage: String? = nil,
        lastInteractionKind: PaneAgentInteractionKind? = nil,
        resetsPreToolUseSlots: Bool = false
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                windowIDRawValue: windowID?.rawValue,
                worklaneIDRawValue: worklaneID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                lastHumanMessage: nil,
                lastInteractionKindRawValue: nil,
                lastStructuredInteractionText: nil,
                lastStructuredInteractionKindRawValue: nil,
                lastStructuredInteractionConfidenceRawValue: nil,
                lastNotificationText: nil,
                tasksByID: [:],
                updatedAt: now
            )
            record.windowIDRawValue = windowID?.rawValue
            record.worklaneIDRawValue = worklaneID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let transcriptPath = normalizedOptional(transcriptPath) {
                record.transcriptPath = transcriptPath
            }
            if let pid {
                record.pid = pid
            }
            if let lastHumanMessage = normalizedOptional(lastHumanMessage) {
                record.structuredInteractionText = lastHumanMessage
            }
            if let lastInteractionKind {
                record.structuredInteractionKind = lastInteractionKind
            }
            // A fresh / resumed / cleared session: nothing announced before it
            // can still prompt. A compaction restart keeps the batch in flight.
            if resetsPreToolUseSlots {
                record.preToolUseSlotsByAgentID = [:]
            }
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    func rememberStructuredInteraction(
        sessionID: String,
        windowID: WindowID? = nil,
        worklaneID: WorklaneID,
        paneID: PaneID,
        cwd: String?,
        pid: Int32?,
        text: String,
        kind: PaneAgentInteractionKind,
        confidence: AgentSignalConfidence,
        toolUseID: String? = nil,
        toolName: String? = nil,
        agentID: String? = nil,
        consumedPreToolUseID: String? = nil
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                windowIDRawValue: windowID?.rawValue,
                worklaneIDRawValue: worklaneID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                lastHumanMessage: nil,
                lastInteractionKindRawValue: nil,
                lastStructuredInteractionText: nil,
                lastStructuredInteractionKindRawValue: nil,
                lastStructuredInteractionConfidenceRawValue: nil,
                lastNotificationText: nil,
                tasksByID: [:],
                updatedAt: now
            )
            record.windowIDRawValue = windowID?.rawValue
            record.worklaneIDRawValue = worklaneID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            record.structuredInteractionText = normalizedOptional(text)
            record.structuredInteractionKind = kind
            record.structuredInteractionConfidence = confidence
            record.lastStructuredInteractionToolUseID = normalizedOptional(toolUseID)
            record.lastStructuredInteractionToolName = normalizedOptional(toolName)
            record.lastStructuredInteractionAgentID = normalizedOptional(agentID)
            if let consumedPreToolUseID = normalizedOptional(consumedPreToolUseID) {
                let key = ClaudeHookSessionRecord.preToolUseSlotKey(agentID: agentID)
                var slots = record.preToolUseSlotsByAgentID[key] ?? []
                if let index = slots.firstIndex(where: { $0.toolUseID == consumedPreToolUseID }) {
                    slots.remove(at: index)
                }
                record.preToolUseSlotsByAgentID[key] = slots.isEmpty ? nil : slots
            }
            record.lastNotificationText = nil
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    /// Remembers the tool call a PreToolUse announced so a following
    /// PermissionRequest (which has no `tool_use_id`) can be tied to it.
    /// Queued per agent context: a subagent's PreToolUse must not displace
    /// the parent's, and an allowlisted sibling must not displace the call
    /// that is about to prompt.
    func rememberPreToolUse(sessionID: String, toolUseID: String?, toolName: String?, agentID: String?) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty, let toolUseID = normalizedOptional(toolUseID) else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            let key = ClaudeHookSessionRecord.preToolUseSlotKey(agentID: agentID)
            var slots = (record.preToolUseSlotsByAgentID[key] ?? []).filter { $0.toolUseID != toolUseID }
            guard slots.count < ClaudePreToolUseSlot.maximumPerAgent else {
                return
            }
            slots.append(ClaudePreToolUseSlot(toolUseID: toolUseID, toolName: normalizedOptional(toolName)))
            record.preToolUseSlotsByAgentID[key] = slots
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    /// Drops a finished call's announcement. An allowlisted call that never
    /// prompted would otherwise stay queued and be the "oldest match" for the
    /// next PermissionRequest of the same tool.
    func forgetPreToolUse(sessionID: String, toolUseID: String?, agentID: String?) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty, let toolUseID = normalizedOptional(toolUseID) else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            let key = ClaudeHookSessionRecord.preToolUseSlotKey(agentID: agentID)
            let slots = (record.preToolUseSlotsByAgentID[key] ?? []).filter { $0.toolUseID != toolUseID }
            guard slots.count != record.preToolUseSlotsByAgentID[key]?.count else {
                return
            }
            record.preToolUseSlotsByAgentID[key] = slots.isEmpty ? nil : slots
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    func recordNotificationText(sessionID: String, text: String) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            record.lastNotificationText = normalizedOptional(text)
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    /// Forgets the open prompt. Also drops the remembered PreToolUse queues
    /// unless `keepsPreToolUseSlots` is set: the turn-boundary hooks (Stop,
    /// UserPromptSubmit) must not let a dropped PreToolUse in the next turn
    /// inherit a stale id, while mid-turn hooks (PreToolUse, PostToolUse,
    /// subagent start/stop, compaction) must leave the batch's other
    /// announcements in place for the prompts that still follow.
    func clearInteractionContext(sessionID: String, keepsPreToolUseSlots: Bool = false) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            clearInteractionContext(in: &record, keepsPreToolUseSlots: keepsPreToolUseSlots)
            state.sessions[normalizedSessionID] = record
        }
    }

    /// Forgets the open prompt only while it still shows `text`. The spinner
    /// resume in the app races the next PermissionRequest: if the bridge has
    /// already stored a newer prompt, this leaves it alone. The pane may be
    /// showing the Notification message that arrived for the prompt rather
    /// than the prompt text itself, so both count as a match.
    func clearInteractionContext(sessionID: String, ifTextMatches text: String?) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty, let expectedText = normalizedOptional(text) else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID],
                  record.structuredInteractionText == expectedText
                    || record.lastNotificationText == expectedText
            else {
                return
            }
            clearInteractionContext(in: &record, keepsPreToolUseSlots: true)
            state.sessions[normalizedSessionID] = record
        }
    }

    private func clearInteractionContext(in record: inout ClaudeHookSessionRecord, keepsPreToolUseSlots: Bool) {
        record.structuredInteractionText = nil
        record.structuredInteractionKind = nil
        record.structuredInteractionConfidence = nil
        record.lastStructuredInteractionToolUseID = nil
        record.lastStructuredInteractionToolName = nil
        record.lastStructuredInteractionAgentID = nil
        if !keepsPreToolUseSlots {
            record.preToolUseSlotsByAgentID.removeAll()
        }
        record.lastNotificationText = nil
        record.updatedAt = Date().timeIntervalSince1970
    }

    func clearLastHumanMessage(sessionID: String) throws {
        try clearInteractionContext(sessionID: sessionID)
    }

    func updateTask(
        sessionID: String,
        taskID: String,
        isCompleted: Bool
    ) throws -> PaneAgentTaskProgress? {
        let normalizedSessionID = normalized(sessionID)
        let normalizedTaskID = normalized(taskID)
        guard !normalizedSessionID.isEmpty, !normalizedTaskID.isEmpty else {
            return nil
        }

        return try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return nil
            }
            // A new task ID arriving after every prior task is done signals a fresh
            // TodoWrite batch within the same session. Drop the prior batch so the
            // sidebar counter restarts at 0/N instead of accumulating.
            if !isCompleted,
               !record.tasksByID.isEmpty,
               record.tasksByID[normalizedTaskID] == nil,
               record.tasksByID.values.allSatisfy({ $0 }) {
                record.tasksByID.removeAll()
            }
            record.tasksByID[normalizedTaskID] = isCompleted
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
            return progress(from: record.tasksByID)
        }
    }

    func taskProgress(sessionID: String?) throws -> PaneAgentTaskProgress? {
        guard let normalizedSessionID = normalizedOptional(sessionID) else {
            return nil
        }

        return try withLockedState { state in
            guard let record = state.sessions[normalizedSessionID] else {
                return nil
            }
            return progress(from: record.tasksByID)
        }
    }

    @discardableResult
    func consume(
        sessionID: String?,
        fallbackWindowID: WindowID? = nil,
        fallbackWorklaneID: WorklaneID?,
        fallbackPaneID: PaneID?
    ) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state -> ClaudeHookSessionRecord? in
            if let sessionID = normalizedOptional(sessionID),
               let record = state.sessions.removeValue(forKey: sessionID) {
                return record
            }

            guard let fallbackWorklaneID, let fallbackPaneID else {
                return nil
            }

            let matchingKeys = state.sessions
                .filter { _, record in
                    if let fallbackWindowID, record.windowID != fallbackWindowID {
                        return false
                    }
                    return record.worklaneIDRawValue == fallbackWorklaneID.rawValue
                        && record.paneIDRawValue == fallbackPaneID.rawValue
                }
                .map(\.key)

            guard matchingKeys.count == 1, let key = matchingKeys.first else {
                return nil
            }

            return state.sessions.removeValue(forKey: key)
        }
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
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

    private func loadState() -> ClaudeHookSessionStoreFile {
        guard let data = try? Data(contentsOf: stateURL) else {
            return ClaudeHookSessionStoreFile()
        }
        return (try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data)) ?? ClaudeHookSessionStoreFile()
    }

    private func saveState(_ state: ClaudeHookSessionStoreFile) throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func progress(from tasksByID: [String: Bool]) -> PaneAgentTaskProgress? {
        guard !tasksByID.isEmpty else {
            return nil
        }

        let doneCount = tasksByID.values.filter { $0 }.count
        return PaneAgentTaskProgress(doneCount: doneCount, totalCount: tasksByID.count)
    }
}
