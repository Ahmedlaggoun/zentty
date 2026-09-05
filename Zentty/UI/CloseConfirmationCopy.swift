import Foundation

/// Text for the close-pane and close-worklane confirmation alerts.
struct CloseConfirmationCopy: Equatable {
    let messageText: String
    let informativeText: String
    let confirmButtonTitle: String

    static func pane(_ context: PaneCloseConfirmationContext) -> CloseConfirmationCopy {
        let reasonLine: String
        switch context.reason {
        case .runningProcess:
            if let activity = context.activity {
                reasonLine = "\(activity.sentenceText) is still running and will be terminated."
            } else {
                reasonLine = "The running process in this pane will be terminated."
            }
        case .sessionHistory:
            reasonLine = "This pane's session history will be lost."
        }

        let detailLines = [
            context.worklaneName.map { "Worklane: \($0)" },
            context.locationLine.map { "Location: \($0)" },
        ].compactMap { $0 }

        return CloseConfirmationCopy(
            messageText: "Close pane “\(context.paneName)”?",
            informativeText: joined(reasonLine, detailLines),
            confirmButtonTitle: "Close Pane"
        )
    }

    static func worklane(_ context: WorklaneCloseConfirmationContext) -> CloseConfirmationCopy {
        let messageText = context.worklaneName.map { "Close worklane “\($0)”?" }
            ?? "Close this worklane?"

        let informativeText: String
        switch context.reason {
        case .runningProcess:
            informativeText = runningLine(context)
        case .sessionHistory:
            informativeText = historyLine(context)
        }

        return CloseConfirmationCopy(
            messageText: messageText,
            informativeText: informativeText,
            confirmButtonTitle: "Close Worklane"
        )
    }

    // MARK: - Helpers

    private static func runningLine(_ context: WorklaneCloseConfirmationContext) -> String {
        let names = groupedActivityList(context.runningActivities)

        if context.paneCount == 1 {
            if let name = context.runningActivities.first {
                return "\(name) is still running and will be terminated."
            }
            return "The running process in this pane will be terminated."
        }

        let subject = context.runningPaneCount == 1
            ? "\(context.runningPaneCount) of \(context.paneCount) panes has a running process"
            : "\(context.runningPaneCount) of \(context.paneCount) panes have running processes"
        let suffix = names.isEmpty ? "" : ": \(names)"
        return "\(subject) that will be terminated\(suffix)."
    }

    private static func historyLine(_ context: WorklaneCloseConfirmationContext) -> String {
        if context.paneCount == 1 {
            return "Session history in this pane will be lost."
        }
        let count = context.historyPaneCount
        return "Session history in \(count) \(count == 1 ? "pane" : "panes") will be lost."
    }

    /// "Claude Code, Claude Code, pnpm dev" reads like a bug; collapse repeats
    /// into "Claude Code (2), pnpm dev", keeping first-seen order.
    static func groupedActivityList(_ activities: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for activity in activities {
            if counts[activity] == nil {
                order.append(activity)
            }
            counts[activity, default: 0] += 1
        }
        return order
            .map { name in
                let count = counts[name] ?? 1
                return count > 1 ? "\(name) (\(count))" : name
            }
            .joined(separator: ", ")
    }

    private static func joined(_ reasonLine: String, _ detailLines: [String]) -> String {
        guard !detailLines.isEmpty else {
            return reasonLine
        }
        return reasonLine + "\n\n" + detailLines.joined(separator: "\n")
    }
}
