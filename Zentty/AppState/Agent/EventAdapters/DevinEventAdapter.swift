import Foundation

// MARK: - Devin Adapter

/// Devin CLI hooks are Claude Code-format compatible (`hook_event_name`,
/// `session_id`, `prompt_id`, `tool_name`, `tool_input`, `tool_use_id`,
/// `tool_response`) with two structural differences:
///
/// 1. Session IDs are human-readable slugs (`thorn-angora`), not UUIDs.
/// 2. There are no `SubagentStart`/`SubagentStop` events. Subagent lifecycle is
///    inferred from the `run_subagent` or `sidekick` tool call (which one the
///    model uses depends on the configured model): `tool_input` carries
///    `title`, `profile` and `is_background` (`sidekick` instead takes a
///    `message` and `block`); the `PostToolUse` response embeds `agent_id=<id>`
///    in its output text. Hooks fired inside a subagent share the parent's
///    `session_id`/`prompt_id` and carry no `agent_id`, so a `Stop` arriving
///    while a `run_subagent`/`sidekick` call is in flight is the subagent's
///    own turn end, not the parent's.
extension AgentEventBridge {
    static func devinAdapter(
        data: Data,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        subagentStore: AgentSubagentRegistryStore = AgentSubagentRegistryStore()
    ) throws -> [AgentStatusPayload] {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = JSONKeyAccess.firstString(in: json, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        let sessionID = JSONKeyAccess.firstString(in: json, keys: ["session_id", "sessionId"])
        let cwd = JSONKeyAccess.firstString(in: json, keys: ["cwd", "working_directory", "workingDirectory"])
        let toolName = JSONKeyAccess.firstString(in: json, keys: ["tool_name", "toolName"])
        let toolInput = (json["tool_input"] as? [String: Any]) ?? [:]
        let toolUseID = JSONKeyAccess.firstString(in: json, keys: ["tool_use_id", "toolUseId"])
        let toolResponse = json["tool_response"] as? [String: Any]
        let displayName = AgentTool.devin.displayName
        let pid = parseAgentPID(from: environment, key: "ZENTTY_DEVIN_PID")

        switch hookEventName {
        case "SessionStart":
            let target = try currentTarget(from: environment)
            // SessionStart only fires for a genuinely new/resumed session
            // (compaction emits PostCompaction instead), so any entries left
            // behind by a killed run are stale.
            try subagentStore.remove(key: devinSubagentKey(target))
            if let sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: cwd,
                    pid: pid,
                    resetsPreToolUseSlots: true
                )
                try subagentStore.recordRootSession(key: devinSubagentKey(target), sessionID: sessionID)
            }
            var payloads: [AgentStatusPayload] = [
                lifecyclePayload(target: target, toolName: displayName, state: .starting, sessionID: sessionID, cwd: cwd),
            ]
            if let pid {
                payloads.append(pidPayload(target: target, toolName: displayName, pid: pid, event: .attach, sessionID: sessionID))
            }
            return payloads

        case "UserPromptSubmit":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "PreToolUse":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)

            if devinIsQuestionTool(toolName) {
                let message = devinQuestionText(toolInput: toolInput)
                    ?? "Devin is asking a question"
                if let sessionID {
                    try sessionStore.rememberStructuredInteraction(
                        sessionID: sessionID,
                        windowID: target.windowID,
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        cwd: cwd,
                        pid: pid,
                        text: message,
                        kind: .decision,
                        confidence: .explicit,
                        toolUseID: toolUseID,
                        toolName: toolName
                    )
                }
                return [devinInteractionPayload(target: target, text: message, kind: .decision, sessionID: sessionID, cwd: cwd)]
            }

            if let sessionID {
                try sessionStore.rememberPreToolUse(sessionID: sessionID, toolUseID: toolUseID, toolName: toolName, agentID: nil)
            }

            var subagents: PaneAgentSubagentSummary?
            if devinIsSubagentTool(toolName) {
                subagents = try subagentStore.start(key: devinSubagentKey(target), entry: devinSubagentEntry(toolName: toolName, toolUseID: toolUseID, toolInput: toolInput))
            }
            return [lifecyclePayload(
                target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd,
                subagents: subagents
            )]

        case "PostToolUse":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.forgetPreToolUse(sessionID: sessionID, toolUseID: toolUseID, agentID: nil)
            }

            var subagents: PaneAgentSubagentSummary?
            if devinIsSubagentTool(toolName) {
                // Foreground subagents complete inside the tool call; the
                // matching PreToolUse entry retires here. Background calls
                // return immediately with `agent_id=` in the output — re-key
                // the entry to the real agent id so a later `read_subagent`
                // completion can retire it by name.
                if devinSubagentIsBackground(toolInput: toolInput, toolResponse: toolResponse) {
                    if let agentID = devinSubagentAgentID(toolResponse: toolResponse) {
                        _ = try subagentStore.stop(key: devinSubagentKey(target), subagentID: toolUseID)
                        subagents = try subagentStore.start(
                            key: devinSubagentKey(target),
                            entry: devinSubagentEntry(toolName: toolName, toolUseID: agentID, toolInput: toolInput)
                        )
                    }
                } else {
                    subagents = try subagentStore.stop(key: devinSubagentKey(target), subagentID: toolUseID)
                }
            } else if toolName == "read_subagent",
                      let agentID = devinReadSubagentAgentID(toolInput: toolInput),
                      devinReadSubagentFinished(toolResponse: toolResponse) {
                subagents = try subagentStore.stop(key: devinSubagentKey(target), subagentID: agentID)
            }

            // A sibling tool finishing while a question/approval prompt is open
            // must not move the pane off needsInput.
            if let sessionID,
               let existing = try sessionStore.lookup(sessionID: sessionID),
               claudeShouldKeepPendingInteraction(
                   existing: existing,
                   completedToolUseID: toolUseID,
                   completedToolName: toolName
               ) {
                return []
            }
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
            }

            let taskProgress = toolName == "todo_write" ? devinTodoProgress(toolInput: toolInput) : nil
            return [lifecyclePayload(
                target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd,
                taskProgress: taskProgress, subagents: subagents
            )]

        case "PermissionRequest":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            let existing = try sessionID.flatMap { try sessionStore.lookup(sessionID: $0) }
            // PermissionRequest may not carry a tool_use_id; inherit the slot
            // that announced this tool (oldest match wins — PreToolUse fires
            // for a whole parallel batch before the first prompt), falling
            // back to the oldest open slot when names don't line up.
            let slots = existing?.preToolUseSlots(agentID: nil) ?? []
            let resolvedToolUseID = toolUseID
                ?? slots.first(where: { $0.toolName == toolName })?.toolUseID
                ?? slots.first?.toolUseID
            let message = devinPermissionText(toolName: toolName, toolInput: toolInput)
            if let sessionID {
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: cwd ?? existing?.cwd,
                    pid: pid ?? existing?.pid,
                    text: message,
                    kind: .approval,
                    confidence: .explicit,
                    toolUseID: resolvedToolUseID,
                    toolName: toolName,
                    consumedPreToolUseID: resolvedToolUseID
                )
            }
            return [devinInteractionPayload(target: target, text: message, kind: .approval, sessionID: sessionID, cwd: cwd)]

        case "Stop":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            // A Stop while any tool call is still open cannot be the parent's
            // turn end — the parent's Stop only fires when it has no calls in
            // flight. Hooks from inside a subagent share the parent's
            // session_id/prompt_id with no agent_id, so this is a subagent's
            // own Stop. A run_subagent/sidekick call still in flight means a foreground
            // subagent ended; any other open call means a background subagent
            // finished while the parent worked — retire the oldest entry.
            let record = try sessionID.flatMap { try sessionStore.lookup(sessionID: $0) }
            let openSlots = record?.preToolUseSlots(agentID: nil) ?? []
            let key = devinSubagentKey(target)
            let subagents = try subagentStore.summary(key: key)
            // PermissionRequest consumes its tool slot; the pending prompt
            // still identifies an active parent when a tracked child stops.
            let hasPendingParent = record?.structuredInteractionKind != nil && subagents?.isEmpty == false
            if !openSlots.isEmpty || hasPendingParent {
                // Only attribute the Stop to a tracked background subagent when
                // the registry actually holds one — and emit the resulting
                // summary even when it is now empty, so the badge clears.
                if !openSlots.contains(where: { devinIsSubagentTool($0.toolName) }),
                   subagents?.isEmpty == false,
                   let subagents = try? subagentStore.stop(key: key, subagentID: nil, retireOldestWhenUnknown: true) {
                    let pendingKind = record?.structuredInteractionKind
                    return [lifecyclePayload(
                        target: target, toolName: displayName,
                        state: pendingKind == nil ? .running : .needsInput,
                        text: record?.structuredInteractionText,
                        interactionKind: pendingKind,
                        sessionID: sessionID, cwd: cwd, subagents: subagents
                    )]
                }
                return []
            }
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            return [lifecyclePayload(target: target, toolName: displayName, state: .idle, sessionID: sessionID, cwd: cwd, subagents: subagents)]

        case "PostCompaction":
            let target = try devinResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, text: "Compacted", sessionID: sessionID, cwd: cwd)]

        case "SessionEnd":
            let current = currentTargetIfAvailable(from: environment)
            let record = try sessionStore.consume(
                sessionID: sessionID,
                fallbackWindowID: current?.windowID,
                fallbackWorklaneID: current?.worklaneID,
                fallbackPaneID: current?.paneID
            )
            guard let record else { return [] }
            let target = (record.windowID, record.worklaneID, record.paneID)
            try subagentStore.remove(key: AgentSubagentRegistryStore.Key(tool: "devin", worklaneID: record.worklaneID, paneID: record.paneID))
            return [
                AgentStatusPayload(
                    windowID: target.0, worklaneID: target.1, paneID: target.2,
                    state: nil, origin: .explicitHook, toolName: displayName, text: nil,
                    sessionID: record.sessionID, artifactKind: nil, artifactLabel: nil, artifactURL: nil
                ),
                pidPayload(target: target, toolName: displayName, pid: nil, event: .clear, sessionID: record.sessionID),
            ]

        default:
            return []
        }
    }

    // MARK: - Devin helpers

    private static func devinResolvedTarget(
        sessionID: String?,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        if let sessionID,
           let record = try sessionStore.lookup(sessionID: sessionID) {
            return (record.windowID, record.worklaneID, record.paneID)
        }
        return try currentTarget(from: environment)
    }

    private static func devinSubagentKey(
        _ target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)
    ) -> AgentSubagentRegistryStore.Key {
        AgentSubagentRegistryStore.Key(tool: "devin", worklaneID: target.worklaneID, paneID: target.paneID)
    }

    private static func devinIsSubagentTool(_ toolName: String?) -> Bool {
        guard let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return name == "run_subagent" || name == "sidekick"
    }

    private static func devinIsQuestionTool(_ toolName: String?) -> Bool {
        toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ask_user_question"
    }

    private static func devinSubagentIsBackground(toolInput: [String: Any], toolResponse: [String: Any]?) -> Bool {
        if let flag = toolInput["is_background"] as? Bool {
            return flag
        }
        if let flag = toolInput["is_background"] as? NSNumber {
            return flag.boolValue
        }
        // `sidekick` spells the flag `block` — `block: false` is a background
        // handoff; `block` absent (or true) is a blocking foreground call.
        if let block = toolInput["block"] as? Bool {
            return !block
        }
        if let block = toolInput["block"] as? NSNumber {
            return !block.boolValue
        }
        // Older payloads may lack the flag; the background response announces
        // itself ("Background subagent started with agent_id=…" /
        // "Sidekick handoff started (agent_id=sidekick)").
        let output = toolResponse?["output"] as? String ?? ""
        return output.contains("Background subagent") || output.contains("handoff started")
    }

    private static func devinSubagentAgentID(toolResponse: [String: Any]?) -> String? {
        guard let output = toolResponse?["output"] as? String,
              let range = output.range(of: #"agent_id=([A-Za-z0-9_-]+)"#, options: .regularExpression) else {
            return nil
        }
        let match = output[range]
        guard let equals = match.firstIndex(of: "=") else { return nil }
        return String(match[match.index(after: equals)...])
    }

    private static func devinReadSubagentAgentID(toolInput: [String: Any]) -> String? {
        JSONKeyAccess.firstString(in: toolInput, keys: ["agent_id", "agentId", "id"])
    }

    /// A `read_subagent` call only retires an entry when the response reports
    /// the agent finished; a still-running agent's status read must not drop
    /// it from the badge.
    private static func devinReadSubagentFinished(toolResponse: [String: Any]?) -> Bool {
        guard let output = (toolResponse?["output"] as? String)?.lowercased() else {
            return false
        }
        return output.contains("completed") || output.contains("failed") || output.contains("cancelled") || output.contains("finished")
    }

    /// `subagent_explore` resolves through the subagent-model router to
    /// SWE-1.6 by default; `subagent_general` inherits the parent's model,
    /// which the adapter cannot see, so it stays nil. Custom profiles may pin
    /// a model in their definition — also invisible here. A `sidekick` call
    /// has no profile/title — there is exactly one sidekick per session —
    /// so it gets a fixed agent type and nickname.
    private static func devinSubagentEntry(toolName: String?, toolUseID: String?, toolInput: [String: Any]) -> PaneAgentSubagentEntry {
        if toolName?.trimmingCharacters(in: .whitespacesAndNewlines) == "sidekick" {
            return PaneAgentSubagentEntry(
                id: toolUseID ?? UUID().uuidString,
                agentType: "sidekick",
                model: nil,
                nickname: "Sidekick",
                transcriptPath: nil
            )
        }
        let profile = JSONKeyAccess.firstString(in: toolInput, keys: ["profile", "agent_type", "agentType"])
        let title = JSONKeyAccess.firstString(in: toolInput, keys: ["title", "name"])
        let model = profile == "subagent_explore" ? "swe-1-6" : nil
        return PaneAgentSubagentEntry(
            id: toolUseID ?? UUID().uuidString,
            agentType: profile,
            model: model,
            nickname: title,
            transcriptPath: nil
        )
    }

    private static func devinQuestionText(toolInput: [String: Any]) -> String? {
        if let questions = toolInput["questions"] as? [[String: Any]],
           let first = questions.first {
            if let text = JSONKeyAccess.firstString(in: first, keys: ["question", "text", "prompt", "title", "header"]) {
                return text
            }
        }
        return JSONKeyAccess.firstString(in: toolInput, keys: ["question", "prompt", "text", "message"])
    }

    private static func devinPermissionText(toolName: String?, toolInput: [String: Any]) -> String {
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = JSONKeyAccess.firstString(in: toolInput, keys: ["command", "path", "file_path", "filePath", "prompt", "query", "url"])
        switch (name, detail) {
        case let (name?, detail?):
            return "Devin wants to run \(name): \(detail)"
        case let (name?, nil):
            return "Devin wants to run \(name)"
        default:
            return "Devin needs approval"
        }
    }

    /// `todo_write` carries the full todo list in `tool_input.todos` with
    /// `status` values `pending` / `in_progress` / `completed`.
    private static func devinTodoProgress(toolInput: [String: Any]) -> PaneAgentTaskProgress? {
        guard let todos = toolInput["todos"] as? [[String: Any]] else {
            return nil
        }
        return PaneAgentTaskProgress(items: taskItems(fromTodoObjects: todos))
    }

    private static func devinInteractionPayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        text: String,
        kind: PaneAgentInteractionKind,
        sessionID: String?,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: AgentTool.devin.displayName,
            text: text,
            lifecycleEvent: .update,
            interactionKind: kind,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }
}

// MARK: - Adapter conformance

enum DevinEventAdapter: AgentEventAdapting {
    static let adapterName = "devin"
    static let suppressesErrors = true
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.devinAdapter(data: data, environment: environment)
    }
}
