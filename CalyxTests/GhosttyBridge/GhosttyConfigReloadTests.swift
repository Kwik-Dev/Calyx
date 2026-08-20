// GhosttyConfigReloadTests.swift
// CalyxTests
//
// Tests for config hot-reload fix.
//
// These tests verify the expected behavior of ConfigReloadCoordinator,
// which does not exist yet in production code. All tests will FAIL
// with a compilation error until the implementation phase creates
// ConfigReloadCoordinator in the Calyx target.
//
// Expected behavior after the fix:
// 1. Both soft and hard reload always read config from disk
// 2. Hard reload (soft=false) also propagates config to all windows
// 3. Soft reload (soft=true) does NOT propagate to windows
// 4. Config load failure preserves last-known-good config
// 5. Rapid calls are debounced (200ms, last-wins)

import Testing
@testable import Calyx

// MARK: - Mock Implementation

@MainActor
final class MockConfigReloadDeps: ConfigReloadDeps {
    var diskReloadCount = 0
    var propagationCount = 0
    var shouldFailReload = false

    /// Each successful load returns an incrementing generation number.
    private var nextGeneration = 1

    func loadConfigFromDisk() -> Int? {
        diskReloadCount += 1
        guard !shouldFailReload else { return nil }
        let gen = nextGeneration
        nextGeneration += 1
        return gen
    }

    func propagateConfigToAllWindows() {
        propagationCount += 1
    }
}

// MARK: - Tests

@MainActor
@Suite("Config Reload Coordinator Tests")
struct GhosttyConfigReloadTests {

    // ==================== Hard Reload ====================

    @Test("hard reload reads config from disk and propagates to windows")
    func hardReloadReadsAndPropagates() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        coordinator.reloadConfig(soft: false)

        // Wait for debounce (200ms) + margin
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Hard reload must read config from disk")
        #expect(mock.propagationCount == 1,
                "Hard reload must propagate config to all windows")
        #expect(coordinator.configGeneration == 1,
                "Config generation should advance to 1 after successful reload")
    }

    // ==================== Soft Reload ====================

    @Test("soft reload reads config from disk without propagation")
    func softReloadReadsWithoutPropagation() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        coordinator.reloadConfig(soft: true)

        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Soft reload must ALSO read config from disk (not reuse old)")
        #expect(mock.propagationCount == 0,
                "Soft reload must NOT propagate to windows")
        #expect(coordinator.configGeneration == 1,
                "Config generation should advance even for soft reload")
    }

    // ==================== Failure Handling ====================

    @Test("reload failure preserves last-known-good config")
    func reloadFailureKeepsLastKnownGood() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // First: successful reload to establish a known-good config
        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(coordinator.configGeneration == 1, "Precondition: first reload succeeds")

        // Now make disk reload fail
        mock.shouldFailReload = true
        mock.diskReloadCount = 0
        mock.propagationCount = 0

        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Disk reload should still be attempted")
        #expect(mock.propagationCount == 0,
                "No propagation should occur on failure")
        #expect(coordinator.configGeneration == 1,
                "Config generation must NOT change on failure (last-known-good preserved)")
    }

    @Test("reload failure from initial state keeps generation at zero")
    func reloadFailureFromInitialState() async throws {
        let mock = MockConfigReloadDeps()
        mock.shouldFailReload = true
        let coordinator = ConfigReloadCoordinator(deps: mock)

        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Disk reload should be attempted even if it will fail")
        #expect(mock.propagationCount == 0,
                "No propagation on failure")
        #expect(coordinator.configGeneration == 0,
                "Config generation should remain at 0 (no successful load)")
    }

    // ==================== Debounce ====================

    @Test("debounce coalesces rapid reload calls into one execution")
    func debounceCoalescesRapidCalls() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // Fire 5 rapid reloads within the debounce window
        for _ in 0..<5 {
            coordinator.reloadConfig(soft: false)
        }

        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Only 1 disk reload should occur despite 5 rapid calls")
        #expect(mock.propagationCount == 1,
                "Only 1 propagation should occur despite 5 rapid calls")
        #expect(coordinator.configGeneration == 1,
                "Config generation should advance only once")
    }

    @Test("debounce uses last-wins semantics for soft flag")
    func debounceLastWinsSemantic() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // First call is hard reload, but last call is soft reload.
        // The debounced execution should use soft=true (last wins).
        coordinator.reloadConfig(soft: false)
        coordinator.reloadConfig(soft: false)
        coordinator.reloadConfig(soft: true)  // last call wins

        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Only 1 disk reload should occur")
        #expect(mock.propagationCount == 0,
                "Last call was soft=true, so no propagation")
    }

    @Test("debounce timer resets on each new call")
    func debounceTimerResetsOnNewCall() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // Call, wait 100ms (less than 200ms debounce), call again.
        // The first call should be cancelled, only the second executes.
        coordinator.reloadConfig(soft: true)
        try await Task.sleep(for: .milliseconds(100))
        coordinator.reloadConfig(soft: false)  // resets timer, switches to hard

        // Wait for the second debounce to fire
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1,
                "Only the second (reset) call should execute")
        #expect(mock.propagationCount == 1,
                "Second call was hard reload, so propagation should occur")
    }

    // ==================== Sequential Reloads ====================

    @Test("sequential reloads after debounce both execute")
    func sequentialReloadsBothExecute() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // First reload
        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 1)
        #expect(mock.propagationCount == 1)
        #expect(coordinator.configGeneration == 1)

        // Second reload (after debounce window has passed)
        coordinator.reloadConfig(soft: true)
        try await Task.sleep(for: .milliseconds(350))

        #expect(mock.diskReloadCount == 2,
                "Second reload should also read from disk")
        #expect(mock.propagationCount == 1,
                "Second reload was soft, so propagation count should not increase")
        #expect(coordinator.configGeneration == 2,
                "Config generation should advance to 2")
    }

    // ==================== Recovery After Failure ====================

    @Test("successful reload after failure updates config normally")
    func recoveryAfterFailure() async throws {
        let mock = MockConfigReloadDeps()
        let coordinator = ConfigReloadCoordinator(deps: mock)

        // Fail first
        mock.shouldFailReload = true
        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(coordinator.configGeneration == 0, "Precondition: failed reload")

        // Now succeed
        mock.shouldFailReload = false
        coordinator.reloadConfig(soft: false)
        try await Task.sleep(for: .milliseconds(350))

        #expect(coordinator.configGeneration == 1,
                "Recovery reload should advance generation")
        #expect(mock.propagationCount == 1,
                "Recovery reload should propagate (hard reload)")
    }
}
