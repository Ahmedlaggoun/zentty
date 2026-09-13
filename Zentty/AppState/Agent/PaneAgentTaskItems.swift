import Foundation

/// Normalized status of a single task-list item as rendered in the sidebar.
enum PaneAgentTaskItemStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case done

    /// Maps every status spelling observed across harnesses onto the three
    /// sidebar states. `cancelled` counts as done, matching how the
    /// counts-only paths treat it.
    init(rawHarnessStatus: String?) {
        switch rawHarnessStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done", "finished", "cancelled":
            self = .done
        case "in_progress", "in-progress", "inprogress", "active", "doing", "running":
            self = .inProgress
        default:
            self = .pending
        }
    }
}

/// One entry of an agent's task list: harness id (or a stable fallback) plus
/// the display title and normalized status.
struct PaneAgentTaskItem: Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let status: PaneAgentTaskItemStatus

    init(id: String? = nil, title: String, status: PaneAgentTaskItemStatus) {
        self.id = id ?? title
        self.title = title
        self.status = status
    }

    /// Decodes the JSON array produced by `PaneAgentTaskProgress.itemsTransportJSON`.
    static func transportItems(fromJSON json: String?) -> [PaneAgentTaskItem]? {
        guard let json, let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([PaneAgentTaskItem].self, from: data),
              !items.isEmpty else {
            return nil
        }
        return items
    }
}

extension PaneAgentTaskProgress {
    /// JSON array encoding of `items` used on the IPC / notification transport.
    var itemsTransportJSON: String? {
        guard !items.isEmpty,
              let data = try? JSONEncoder.taskItemTransport.encode(items) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A counts-only update (no items) keeps the current item list while the
    /// counts are unchanged; different counts mean the items are stale and the
    /// incoming snapshot wins.
    func mergingCountsOnlyUpdate(_ incoming: PaneAgentTaskProgress) -> PaneAgentTaskProgress {
        guard incoming.items.isEmpty,
              !items.isEmpty,
              incoming.doneCount == doneCount,
              incoming.totalCount == totalCount else {
            return incoming
        }
        return self
    }
}

private extension JSONEncoder {
    static let taskItemTransport: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
