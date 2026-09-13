import Foundation
import OSLog

private let agentManifestLogger = Logger(
    subsystem: "be.zenjoy.zentty",
    category: "AgentManifestRegistry"
)

/// Loads and indexes `agents/*.json` agent manifests. Shared by the app and the
/// ZenttyCLI target so both resolve the same manifest set.
struct AgentManifestRegistry: Sendable {
    /// Lazily loaded shared registry (bundled `agents/`, then
    /// `ZENTTY_AGENT_MANIFEST_DIRS`, then `~/.config/zentty/agents/`).
    static let shared = load()

    /// Injectable for tests; production code reads the lazily loaded shared
    /// registry. Single provider shared by AgentTool, AgentBootstrapTool,
    /// consent, restore, icon, theme-sync, and session-environment lookups.
    nonisolated(unsafe) static var provider: () -> AgentManifestRegistry = {
        .shared
    }

    /// Manifests sorted by id.
    let manifests: [AgentManifest]

    init(manifests: [AgentManifest]) {
        self.manifests = Self.assemble(manifests)
    }

    func manifest(id: String) -> AgentManifest? {
        manifests.first { $0.id == id }
    }

    func manifest(displayName: String) -> AgentManifest? {
        let needle = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return manifests.first { $0.displayName.compare(needle, options: .caseInsensitive) == .orderedSame }
    }

    func manifest(forBinary binary: String) -> AgentManifest? {
        let name = (binary as NSString).lastPathComponent
        return manifests.first { $0.binaries.contains(name) }
    }

    /// Uses the same leading-token logic as `AgentTool`'s builtin matchers,
    /// applied to every manifest's `binaries`.
    func tool(matchingProcessNameOrTitle value: String) -> AgentTool? {
        for manifest in manifests {
            let tokens = manifest.binaries.map { $0.lowercased() }
            if AgentTool.matchesLeadingToken(value, tokens: tokens) {
                return .custom(manifest.displayName)
            }
        }
        return nil
    }

    /// `id=Display Name=bin1,bin2;id2=...` consumed by the shell integrations.
    var shellTable: String {
        manifests
            .map { "\($0.id)=\($0.displayName)=\($0.binaries.joined(separator: ","))" }
            .joined(separator: ";")
    }

    static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> AgentManifestRegistry {
        var loaded: [AgentManifest] = []
        // Later sources win by id: bundled < env dirs < user config dir.
        if let bundled = bundledAgentsDirectory(bundle: bundle, fileManager: fileManager) {
            loaded += loadManifests(from: bundled, fileManager: fileManager)
        }
        if let dirsValue = environment["ZENTTY_AGENT_MANIFEST_DIRS"],
           !dirsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for entry in dirsValue.split(separator: ":", omittingEmptySubsequences: true) {
                let dir = URL(fileURLWithPath: String(entry), isDirectory: true)
                loaded += loadManifests(from: dir, fileManager: fileManager)
            }
        }
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let userDir = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        loaded += loadManifests(from: userDir, fileManager: fileManager)
        return AgentManifestRegistry(manifests: loaded)
    }

    /// Applies validation, id-override (later wins), and displayName
    /// uniqueness while preserving load order for diagnostics.
    private static func assemble(_ candidates: [AgentManifest]) -> [AgentManifest] {
        var byID: [String: AgentManifest] = [:]
        var order: [String] = []
        for manifest in candidates {
            if let error = manifest.validationError() {
                agentManifestLogger.error(
                    "Skipping agent manifest '\(manifest.id, privacy: .public)': \(error, privacy: .public)"
                )
                continue
            }
            if let clash = byID.values.first(where: {
                $0.id != manifest.id && $0.displayName == manifest.displayName
            }) {
                agentManifestLogger.error(
                    "Skipping agent manifest '\(manifest.id, privacy: .public)': displayName collides with '\(clash.id, privacy: .public)'"
                )
                continue
            }
            if byID[manifest.id] == nil {
                order.append(manifest.id)
            }
            byID[manifest.id] = manifest
        }
        return order.compactMap { byID[$0] }.sorted { $0.id < $1.id }
    }

    private static func loadManifests(
        from directory: URL,
        fileManager: FileManager
    ) -> [AgentManifest] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var manifests: [AgentManifest] = []
        for fileURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                manifests.append(try JSONDecoder().decode(AgentManifest.self, from: data))
            } catch {
                agentManifestLogger.error(
                    "Skipping agent manifest at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return manifests
    }

    /// The bundled `agents/` resource directory. `Bundle.main` of the ZenttyCLI
    /// binary lives at `Contents/Resources/bin/shared/`, not inside a bundle, so
    /// ancestors are probed the same way `AgentStatusHelper.candidateBundles`
    /// locates `Contents/Resources`.
    private static func bundledAgentsDirectory(
        bundle: Bundle,
        fileManager: FileManager
    ) -> URL? {
        var roots: [URL] = []
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL)
        }
        var cursor = bundle.bundleURL
        for _ in 0..<8 {
            roots.append(cursor)
            roots.append(
                cursor
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
            )
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
        for root in roots {
            let directory = root.appendingPathComponent("agents", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
        }
        return nil
    }
}
