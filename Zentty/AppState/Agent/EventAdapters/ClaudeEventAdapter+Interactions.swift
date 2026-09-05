import Foundation

// MARK: - Claude Adapter: prompts and pending interactions

extension AgentEventBridge {
    /// Whether a PostToolUse belongs to a tool *other* than the one whose
    /// permission / question prompt is open, in which case the prompt stays.
    /// Prefers `tool_use_id`; falls back to `tool_name` because Claude Code's
    /// PermissionRequest payload has no id and the PreToolUse matcher only
    /// covers Bash/Write/Edit, so the id is often unknown.
    static func claudeShouldKeepPendingInteraction(
        existing: ClaudeHookSessionRecord?,
        completedToolUseID: String?,
        completedToolName: String? = nil
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true
        else {
            return false
        }
        if let pendingToolUseID = existing.lastStructuredInteractionToolUseID,
           let completedToolUseID = AgentInteractionClassifier.trimmed(completedToolUseID) {
            return pendingToolUseID != completedToolUseID
        }
        if let pendingToolName = existing.lastStructuredInteractionToolName,
           let completedToolName = AgentInteractionClassifier.trimmed(completedToolName) {
            return pendingToolName != completedToolName
        }
        return false
    }

    /// `tool_use_id` for a PermissionRequest, taken from the PreToolUse that
    /// announced the same tool call (same tool, same agent context).
    static func claudeInheritedPreToolUseID(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> String? {
        guard let existing,
              let preToolUseID = existing.lastPreToolUseID,
              let toolName = AgentInteractionClassifier.trimmed(input.toolName),
              existing.lastPreToolUseToolName == toolName,
              existing.lastPreToolUseAgentID == AgentInteractionClassifier.trimmed(input.agentID)
        else {
            return nil
        }
        return preToolUseID
    }

    static func claudeDescribePermissionRequest(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> (text: String, interactionKind: PaneAgentInteractionKind) {
        if input.toolName == "AskUserQuestion" {
            if let prompt = claudeDescribeAskUserQuestion(toolInput: input.toolInput) {
                return prompt
            }
            if let existingText = existing?.structuredInteractionText,
               existing?.structuredInteractionKind == .decision {
                return (existingText, .decision)
            }
            return ("Claude is waiting for your decision", .decision)
        }
        return (
            AgentInteractionClassifier.trimmed(input.message) ?? "Claude needs your approval",
            .approval
        )
    }

    static func claudeDescribeAskUserQuestion(toolInput: [String: Any]) -> (text: String, interactionKind: PaneAgentInteractionKind)? {
        guard let questions = toolInput["questions"] as? [[String: Any]],
              let first = questions.first else {
            return nil
        }
        var lines: [String] = []
        if let question = first["question"] as? String, !question.isEmpty {
            lines.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            lines.append(header)
        }
        let options = first["options"] as? [[String: Any]]
        if let options {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                lines.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }
        guard !lines.isEmpty else { return nil }
        return (text: lines.joined(separator: "\n"), interactionKind: .decision)
    }

    static func claudePreferredStructuredInteractionText(
        existingText: String?,
        existingKind: PaneAgentInteractionKind?,
        candidateText: String,
        candidateKind: PaneAgentInteractionKind
    ) -> String {
        guard existingKind == candidateKind else { return candidateText }
        return AgentInteractionClassifier.preferredWaitingMessage(existing: existingText, candidate: candidateText) ?? candidateText
    }

    static func claudeShouldReplaceStructuredInteractionText(
        with notificationText: String,
        structuredKind: PaneAgentInteractionKind
    ) -> Bool {
        if AgentInteractionClassifier.isGenericNeedsInputMessage(notificationText)
            || AgentInteractionClassifier.isGenericApprovalMessage(notificationText) {
            return false
        }
        switch structuredKind {
        case .approval, .auth, .genericInput:
            return AgentInteractionClassifier.requiresHumanInput(message: notificationText)
        case .question, .decision, .none:
            return false
        }
    }
}
