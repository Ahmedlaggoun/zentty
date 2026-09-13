import Foundation
import OSLog

private let manifestWrapperLogger = Logger(
    subsystem: "be.zenjoy.zentty",
    category: "AgentManifestWrapper"
)

/// Writes one thin wrapper script per manifest binary under
/// `~/.config/zentty/run/agent-wrappers/<id>/<binary>`. Unlike the bundled
/// `Resources/bin/<tool>/` wrappers these live in the runtime root because the
/// manifest set is dynamic — the app re-materializes them at startup and prunes
/// ids whose manifest disappeared.
enum AgentManifestWrapperMaterializer {
    /// Wrapper bin directories for the most recent `materialize` call, read by
    /// `WorklaneSessionEnvironment.make` so panes don't re-materialize.
    nonisolated(unsafe) private(set) static var materializedDirectories: [String] = []

    /// Materialize wrappers for `manifests` under `rootURL` and record the
    /// resulting directory list for `materializedDirectories`.
    static func materialize(
        manifests: [AgentManifest],
        rootURL: URL,
        sharedWrapperPath: String,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let directories = try writeWrappers(
            manifests: manifests,
            rootURL: rootURL,
            sharedWrapperPath: sharedWrapperPath,
            fileManager: fileManager
        )
        materializedDirectories = directories
        return directories
    }

    /// Clears the cached directory list. Test-only: keeps `materialize` calls
    /// in one test from leaking wrapper paths into unrelated tests that read
    /// `ZENTTY_ALL_WRAPPER_BIN_DIRS`.
    static func resetMaterializedDirectories() {
        materializedDirectories = []
    }

    private static func writeWrappers(
        manifests: [AgentManifest],
        rootURL: URL,
        sharedWrapperPath: String,
        fileManager: FileManager
    ) throws -> [String] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let supportDirectory = URL(fileURLWithPath: sharedWrapperPath, isDirectory: false)
            .deletingLastPathComponent()
            .path
        let currentIDs = Set(manifests.map(\.id))
        var directories: [String] = []

        for manifest in manifests {
            let directoryURL = rootURL.appendingPathComponent(manifest.id, isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for binary in manifest.binaries {
                let wrapperURL = directoryURL.appendingPathComponent(binary, isDirectory: false)
                try wrapperScript(
                    toolID: manifest.id,
                    binaries: manifest.binaries,
                    supportDirectory: supportDirectory
                ).write(to: wrapperURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
            }
            directories.append(directoryURL.path)
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries {
                guard !currentIDs.contains(entry.lastPathComponent) else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    manifestWrapperLogger.error(
                        "Failed to remove stale manifest wrapper dir \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        return directories.sorted()
    }

    private static func wrapperScript(
        toolID: String,
        binaries: [String],
        supportDirectory: String
    ) -> String {
        """
        #!/usr/bin/env bash
        export ZENTTY_AGENT_TOOL="\(toolID)"
        export ZENTTY_AGENT_REAL_BINARIES="\(binaries.joined(separator: ":"))"
        export ZENTTY_AGENT_WRAPPER_DIR="$(cd "$(dirname "$0")" && pwd)"
        exec "${ZENTTY_WRAPPER_SUPPORT_DIR:-\(supportDirectory)}/zentty-agent-wrapper" "$@"

        """
    }
}
