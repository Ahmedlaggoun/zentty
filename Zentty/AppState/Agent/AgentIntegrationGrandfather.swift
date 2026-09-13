import Foundation
import os

/// One-time migration that marks already-installed persistent agents as `on`
/// so users upgrading to the consent feature are never re-prompted for hooks
/// they already have on disk. Runs once, guarded by `grandfatheredV1`.
///
/// Ephemeral agents are on by default and never need grandfathering. Persistent
/// agents the user has never installed stay at their `ask` default, so their
/// next manual launch prompts as intended for new installs.
enum AgentIntegrationGrandfather {
    /// Detect existing on-disk installs and record them as `on`, then set the
    /// migration flag. A no-op after the first successful run. Call once at
    /// startup, before any workspace restore spawns agents.
    static func migrateIfNeeded(
        configStore: AppConfigStore,
        isInstalled: (AgentBootstrapTool) -> Bool = AgentIntegrationHooks.isInstalled
    ) {
        guard !configStore.current.agentIntegrations.grandfatheredV1 else { return }

        var detected: [String: AgentIntegrationState] = [:]
        for tool in AgentIntegrationConsent.persistentTools where isInstalled(tool) {
            detected[tool.id] = .on
        }

        do {
            try configStore.update { config in
                // Don't clobber any state the user has already set explicitly.
                for (agentID, state) in detected where config.agentIntegrations.states[agentID] == nil {
                    config.agentIntegrations.states[agentID] = state
                }
                config.agentIntegrations.grandfatheredV1 = true
            }
        } catch {
            agentIntegrationLogger.error(
                "Failed to persist grandfather migration: \(error.localizedDescription, privacy: .public)")
        }
    }
}
