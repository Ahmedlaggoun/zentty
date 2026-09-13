import Darwin
import Foundation
import os

/// Devin writes in-session settings changes (permission grants, `/config`
/// edits) back to whatever `--config` path it was given — in Zentty's case a
/// disposable per-pane overlay. `sync` diffs the overlay against the snapshot
/// written at launch and merges the changed leaves into the real config file
/// Devin would have written (`~/.config/devin/config.json` or a user-supplied
/// `--config` path), so those settings survive the next launch.
enum DevinConfigWriteBack {
    /// Environment key carrying the absolute path of the overlay config.json.
    static let overlayEnvironmentKey = "ZENTTY_DEVIN_CONFIG_OVERLAY"
    /// Environment key carrying the absolute path of the real config Devin
    /// would have written (user config or user-supplied `--config`).
    static let sourceEnvironmentKey = "ZENTTY_DEVIN_CONFIG_SOURCE"
    /// Sibling of the overlay holding the exact bytes written at launch.
    static let snapshotFileName = "config.launch.json"

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "DevinConfigWriteBack")

    private enum Edit {
        case set(path: [String], value: Any)
        case remove(path: [String])
    }

    /// Pure 3-way merge at leaf granularity. `base` is the snapshot taken at
    /// launch, `current` the overlay as it is now, `target` the real config as
    /// it is on disk now. Returns nil when `base` and `current` are
    /// semantically identical (nothing to apply). The top-level `hooks` key is
    /// ignored entirely — it is owned by the overlay and never written back.
    /// Keys of `target` not touched by a change are preserved verbatim.
    static func merged(base: [String: Any], current: [String: Any], target: [String: Any]) -> [String: Any]? {
        var edits: [Edit] = []
        collectEdits(base: base, current: current, path: [], edits: &edits)
        guard !edits.isEmpty else { return nil }

        var result = target
        for edit in edits {
            switch edit {
            case .set(let path, let value):
                set(value, at: path, in: &result)
            case .remove(let path):
                remove(at: path, in: &result)
            }
        }
        return result
    }

    /// Reads the overlay and snapshot (plus the source when it exists, all
    /// JSONC-permissive; a missing source reads as an empty object), merges
    /// the launch-to-now diff into the source and writes it atomically as
    /// plain JSON, then refreshes the snapshot with the current overlay bytes
    /// so the same diff is never re-applied. Returns true when the source file
    /// was written. An exclusive `flock` on "<source>.zentty-lock" guards the
    /// read-modify-write — two panes may sync concurrently.
    static func sync(
        overlayURL: URL,
        snapshotURL: URL,
        sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let overlayData = try? Data(contentsOf: overlayURL),
              let overlay = parseObject(overlayData),
              let snapshotData = try? Data(contentsOf: snapshotURL),
              let snapshot = parseObject(snapshotData) else {
            return false
        }

        try fileManager.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lockURL = URL(fileURLWithPath: sourceURL.path + ".zentty-lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { flock(descriptor, LOCK_UN) }

        let target = (try? Data(contentsOf: sourceURL)).flatMap(parseObject) ?? [:]

        var didWrite = false
        if let result = merged(base: snapshot, current: overlay, target: target),
           !(result as AnyObject).isEqual(target) {
            let outputData = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try outputData.write(to: sourceURL, options: .atomic)
            didWrite = true
        }

        try overlayData.write(to: snapshotURL, options: .atomic)
        return didWrite
    }

    /// Hook entry point: no-ops when either environment key is blank and logs
    /// instead of throwing — a failed write-back must never break the hook.
    static func syncIfNeeded(environment: [String: String], fileManager: FileManager = .default) {
        guard let overlayPath = environment[overlayEnvironmentKey]?.nilIfBlank,
              let sourcePath = environment[sourceEnvironmentKey]?.nilIfBlank else {
            return
        }
        let overlayURL = URL(fileURLWithPath: overlayPath, isDirectory: false)
        let snapshotURL = overlayURL.deletingLastPathComponent()
            .appendingPathComponent(snapshotFileName, isDirectory: false)
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: false)
        do {
            _ = try sync(
                overlayURL: overlayURL,
                snapshotURL: snapshotURL,
                sourceURL: sourceURL,
                fileManager: fileManager
            )
        } catch {
            logger.error("devin config write-back failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func isIgnoredKey(_ key: String, at path: [String]) -> Bool {
        path.isEmpty && key == "hooks"
    }

    private static func collectEdits(
        base: [String: Any],
        current: [String: Any],
        path: [String],
        edits: inout [Edit]
    ) {
        for (key, baseValue) in base where !isIgnoredKey(key, at: path) {
            guard let currentValue = current[key] else {
                edits.append(.remove(path: path + [key]))
                continue
            }
            if let baseDict = baseValue as? [String: Any],
               let currentDict = currentValue as? [String: Any] {
                collectEdits(base: baseDict, current: currentDict, path: path + [key], edits: &edits)
            } else if !(baseValue as AnyObject).isEqual(currentValue) {
                edits.append(.set(path: path + [key], value: currentValue))
            }
        }
        for (key, currentValue) in current where base[key] == nil && !isIgnoredKey(key, at: path) {
            edits.append(.set(path: path + [key], value: currentValue))
        }
    }

    private static func set(_ value: Any, at path: [String], in dictionary: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            dictionary[key] = value
        } else {
            var child = dictionary[key] as? [String: Any] ?? [:]
            set(value, at: Array(path.dropFirst()), in: &child)
            dictionary[key] = child
        }
    }

    private static func remove(at path: [String], in dictionary: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            dictionary.removeValue(forKey: key)
        } else if var child = dictionary[key] as? [String: Any] {
            remove(at: Array(path.dropFirst()), in: &child)
            dictionary[key] = child
        }
    }

    private static func parseObject(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let uncommented = JSONCRelaxedParse.stripComments(in: data),
              let cleaned = JSONCRelaxedParse.stripTrailingCommas(in: uncommented) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any]
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
