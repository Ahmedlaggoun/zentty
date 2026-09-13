import Foundation

struct OpenCodeOverlayRoots: Equatable {
    let toolDirectoryURL: URL
    let configHomeURL: URL
    let configDirectoryURL: URL
    let stateHomeURL: URL
    let stateDirectoryURL: URL
}

/// Per-launch overlay layout for the OpenCode plugin family (opencode plus
/// `opencode-plugin` manifest agents like kilo). `toolID` is the pane-local
/// overlay leaf (`launch/<worklane>/<pane>/<toolID>`); `configDirName` is the
/// agent's own config directory name (`opencode`, `kilo`) used for the
/// `xdg-config-home/<name>` and `xdg-state-home/<name>` leaves.
enum OpenCodeOverlayLayout {
    static func toolDirectoryURL(
        runtimeDirectoryURL: URL,
        worklaneID: WorklaneID,
        paneID: PaneID,
        toolID: String = "opencode"
    ) -> URL {
        runtimeDirectoryURL
            .appendingPathComponent("launch", isDirectory: true)
            .appendingPathComponent(worklaneID.rawValue, isDirectory: true)
            .appendingPathComponent(paneID.rawValue, isDirectory: true)
            .appendingPathComponent(toolID, isDirectory: true)
    }

    static func overlayRoots(
        runtimeDirectoryURL: URL,
        worklaneID: WorklaneID,
        paneID: PaneID,
        toolID: String = "opencode",
        configDirName: String = "opencode"
    ) -> OpenCodeOverlayRoots {
        overlayRoots(
            for: toolDirectoryURL(
                runtimeDirectoryURL: runtimeDirectoryURL,
                worklaneID: worklaneID,
                paneID: paneID,
                toolID: toolID
            ),
            configDirName: configDirName
        )
    }

    static func overlayRoots(
        for toolDirectoryURL: URL,
        configDirName: String = "opencode"
    ) -> OpenCodeOverlayRoots {
        let configHomeURL = toolDirectoryURL.appendingPathComponent("xdg-config-home", isDirectory: true)
        let stateHomeURL = toolDirectoryURL.appendingPathComponent("xdg-state-home", isDirectory: true)
        return OpenCodeOverlayRoots(
            toolDirectoryURL: toolDirectoryURL,
            configHomeURL: configHomeURL,
            configDirectoryURL: configHomeURL.appendingPathComponent(configDirName, isDirectory: true),
            stateHomeURL: stateHomeURL,
            stateDirectoryURL: stateHomeURL.appendingPathComponent(configDirName, isDirectory: true)
        )
    }
}
