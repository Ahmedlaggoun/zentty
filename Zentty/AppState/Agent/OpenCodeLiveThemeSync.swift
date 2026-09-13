import AppKit
import Darwin
import Foundation
import os

struct OpenCodeRunningPane: Equatable, Sendable {
    let worklaneID: WorklaneID
    let paneID: PaneID
    let pid: Int32
    /// Pane-local overlay leaf (`launch/<worklane>/<pane>/<toolID>`).
    var toolID: String = "opencode"
    /// The agent's own config dir name (`opencode`, `kilo`, …).
    var configDirName: String = "opencode"
}

enum OpenCodeLiveThemeSync {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "OpenCodeLiveThemeSync")

    static func runningPanes(
        in worklanes: [WorklaneState],
        registry: AgentManifestRegistry = AgentManifestRegistry.provider()
    ) -> [OpenCodeRunningPane] {
        worklanes.flatMap { worklane in
            worklane.auxiliaryStateByPaneID.compactMap { paneID, auxiliaryState in
                guard let agentStatus = auxiliaryState.agentStatus,
                      let pid = agentStatus.trackedPID
                else {
                    return nil
                }

                switch agentStatus.tool {
                case .openCode:
                    return OpenCodeRunningPane(
                        worklaneID: worklane.id,
                        paneID: paneID,
                        pid: pid
                    )
                case .custom(let name):
                    guard let manifest = registry.manifest(displayName: name),
                          manifest.family == .opencodePlugin,
                          let options = manifest.opencodePlugin
                    else {
                        return nil
                    }
                    return OpenCodeRunningPane(
                        worklaneID: worklane.id,
                        paneID: paneID,
                        pid: pid,
                        toolID: manifest.id,
                        configDirName: options.configDirName
                    )
                default:
                    return nil
                }
            }
        }
    }

    @discardableResult
    static func syncRunningPanes(
        _ panes: [OpenCodeRunningPane],
        runtimeDirectoryURL: URL,
        appConfig: AppConfig,
        configEnvironment: GhosttyConfigEnvironment,
        effectiveAppearance: NSAppearance,
        themeDirectories: [URL] = GhosttyThemeLibrary.resolverThemeDirectories(),
        fileManager: FileManager = .default,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive,
        signaler: (Int32) throws -> Void = defaultSignaler
    ) throws -> [Int32] {
        guard appConfig.appearance.syncOpenCodeThemeWithTerminal else {
            return []
        }

        var refreshedPIDs: [Int32] = []
        var seenPIDs: Set<Int32> = []

        for pane in panes {
            guard seenPIDs.insert(pane.pid).inserted else {
                continue
            }
            guard isProcessAlive(pane.pid) else {
                continue
            }

            let overlayConfigDirectoryURL = OpenCodeOverlayLayout
                .overlayRoots(
                    runtimeDirectoryURL: runtimeDirectoryURL,
                    worklaneID: pane.worklaneID,
                    paneID: pane.paneID,
                    toolID: pane.toolID,
                    configDirName: pane.configDirName
                )
                .configDirectoryURL

            guard OpenCodeThemeSync.isSyncedThemeSelected(in: overlayConfigDirectoryURL) else {
                continue
            }

            let syncedThemeURL = OpenCodeThemeSync.syncedThemeFileURL(in: overlayConfigDirectoryURL)
            guard fileManager.fileExists(atPath: syncedThemeURL.path) else {
                continue
            }

            do {
                let didWrite = try OpenCodeThemeSync.writeSyncedThemeFile(
                    toOverlayConfigDirectory: overlayConfigDirectoryURL,
                    configEnvironment: configEnvironment,
                    effectiveAppearance: effectiveAppearance,
                    themeDirectories: themeDirectories,
                    fileManager: fileManager
                )
                guard didWrite else {
                    continue
                }

                try signaler(pane.pid)
                refreshedPIDs.append(pane.pid)
            } catch {
                logger.error(
                    "Failed to live sync OpenCode theme for worklane=\(pane.worklaneID.rawValue, privacy: .public) pane=\(pane.paneID.rawValue, privacy: .public) pid=\(pane.pid): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return refreshedPIDs
    }

    private static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private static func defaultSignaler(_ pid: Int32) throws {
        guard kill(pid, SIGUSR2) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
