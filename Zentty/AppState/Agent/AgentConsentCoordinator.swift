import Foundation
import os

/// Coordinates the first-run integration-consent handshake between the IPC
/// server — which blocks an agent launch on a background thread — and the
/// MainActor consent panel.
///
/// Concurrent consent requests for the SAME agent coalesce onto a single panel
/// and share its decision (so a workspace that launches two of the same agent
/// shows one prompt, not two). The chosen state is persisted to AppConfig so
/// later launches and the Settings UI reflect it.
@MainActor
final class AgentConsentCoordinator {
    static let shared = AgentConsentCoordinator()

    /// Presents the consent panel for `tool`, invoking `completion` exactly once
    /// with the user's choice (`.on` to install hooks, `.off` to skip). Wired at
    /// app startup.
    typealias Presenter = @MainActor (_ tool: AgentBootstrapTool, _ completion: @escaping (AgentIntegrationState) -> Void) -> Void

    private var configStore: AppConfigStore?
    private var presenter: Presenter?
    private var waiters: [AgentBootstrapTool: [(AgentIntegrationState) -> Void]] = [:]

    /// Internal (not private) so tests can exercise coalescing on an isolated
    /// instance rather than the shared singleton.
    init() {}

    /// Wire the live config store and the panel presenter. Called once at
    /// startup. Until wired, consent requests resolve to `.off` without
    /// persisting, so a headless or not-yet-initialized app runs degraded
    /// rather than hanging — and the state stays `ask` for a later prompt.
    func configure(configStore: AppConfigStore, presenter: @escaping Presenter) {
        self.configStore = configStore
        self.presenter = presenter
    }

    /// Request a consent decision. Coalesces concurrent requests for the same
    /// tool onto one panel. `completion` fires (on the main actor) with the
    /// resolved state once the user answers.
    func requestDecision(
        tool: AgentBootstrapTool,
        completion: @escaping (AgentIntegrationState) -> Void
    ) {
        // Join an in-flight panel for the same tool instead of opening a second.
        if waiters[tool] != nil {
            waiters[tool]?.append(completion)
            return
        }
        waiters[tool] = [completion]

        guard let presenter else {
            // No panel wired: decline WITHOUT persisting, leaving the state at
            // `ask` so a later launch (with the panel wired) can still prompt.
            resolve(tool: tool, state: .off, persist: false)
            return
        }
        presenter(tool) { [weak self] state in
            self?.resolve(tool: tool, state: state, persist: true)
        }
    }

    private func resolve(tool: AgentBootstrapTool, state: AgentIntegrationState, persist: Bool) {
        if persist {
            do {
                try configStore?.update { config in
                    config.agentIntegrations.states[tool.id] = state
                }
            } catch {
                agentIntegrationLogger.error(
                    "Failed to persist \(tool.id, privacy: .public) consent decision: \(error.localizedDescription, privacy: .public)")
            }
        }
        let completions = waiters[tool] ?? []
        waiters[tool] = nil
        for completion in completions {
            completion(state)
        }
    }
}

extension AgentConsentCoordinator {
    /// Blocks the calling (non-main) thread until the consent panel resolves,
    /// returning the chosen state. The IPC server's per-connection handler runs
    /// on a utility queue, so blocking it here is safe. MUST NOT be called on
    /// the main thread — it would deadlock against the panel.
    ///
    /// On timeout, returns `.off`; the panel may still resolve later and persist
    /// the real choice for the next launch (the wrapper has already fallen back
    /// to a degraded launch by then).
    nonisolated static func awaitDecisionBlocking(
        tool: AgentBootstrapTool,
        timeout: TimeInterval = TimeInterval(
            AgentIPCProtocol.awaitConsentTimeoutSeconds - AgentIPCProtocol.consentPanelTimeoutMargin
        )
    ) -> AgentIntegrationState {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ConsentResultBox()
        Task { @MainActor in
            shared.requestDecision(tool: tool) { state in
                box.set(state)
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value ?? .off
    }
}

/// Thread-safe one-shot holder for the resolved consent state, written on the
/// main actor and read on the IPC worker thread after the semaphore signals.
private final class ConsentResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentIntegrationState?

    var value: AgentIntegrationState? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: AgentIntegrationState) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}
