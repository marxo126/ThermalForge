//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import Observation
import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

/// What the menu-bar label displays. (Feature request #20.)
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case temperature
    case fanSpeed
    case iconOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .temperature: return "Temperature"
        case .fanSpeed: return "Fan speed"
        case .iconOnly: return "Icon only"
        }
    }
}

@MainActor
@Observable
final class AppState {
    var latestStatus: ThermalStatus?
    var activeProfile: FanProfile = .silent
    var monitorState: MonitorState = .idle
    var maxTemp: Float?
    /// Peak fan RPM across all fans, for the menu-bar label's "Fan speed" mode.
    var maxFanRPM: Int?
    var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    /// What the menu-bar label shows: temperature (default), fan speed, or icon
    /// only. Persisted. (Feature request #20.)
    var menuBarDisplay: MenuBarDisplay =
        MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: "menuBarDisplay") ?? "")
        ?? .temperature {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") }
    }
    /// Extra Cool: a sticky modifier that shifts the active profile colder and
    /// louder. The toggle is persisted; the *selected profile* deliberately is
    /// not — the app always starts in Silent (hands-off) on launch for safety,
    /// so a restored `true` here simply takes effect the moment a profile is chosen.
    var extraCool: Bool = UserDefaults.standard.bool(forKey: "extraCool") {
        didSet {
            UserDefaults.standard.set(extraCool, forKey: "extraCool")
            applyProfile(baseProfile)
            TFLogger.shared.profile("Extra Cool \(extraCool ? "ON" : "off")")
        }
    }
    var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }
    /// Minutes after which a non-default profile auto-reverts to Default.
    /// 0 == off. Changing it re-arms the timer.
    var autoRevertMinutes: Int = UserDefaults.standard.integer(forKey: "autoRevertMinutes") {
        didSet {
            UserDefaults.standard.set(autoRevertMinutes, forKey: "autoRevertMinutes")
            armAutoRevert()
        }
    }

    @ObservationIgnored private var monitor: ThermalMonitor?
    @ObservationIgnored private let executor = PrivilegedExecutor()
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var autoRevertTimer: Timer?
    /// Guards against re-entrant recursion when reverting the launchAtLogin
    /// toggle below (the revert re-fires the didSet).
    @ObservationIgnored private var isUpdatingLoginItem = false
    /// The profile the user picked, before any Extra Cool transform.
    @ObservationIgnored private var baseProfile: FanProfile = .silent
    /// Whether the dropdown panel is currently shown. The panel's hosting view
    /// stays alive while hidden and re-renders on any observed change, so we
    /// only feed it the per-tick `latestStatus` while it's actually visible.
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastStatus: ThermalStatus?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Clean state: reset fans to auto on every launch.
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        // Heartbeat is started only when a fan-controlling profile is active
        // (see syncHeartbeat). The default Silent profile needs none.
    }

    deinit {
        heartbeatTimer?.invalidate()
        autoRevertTimer?.invalidate()
    }

    // MARK: - Auto-revert

    /// (Re)arm the auto-revert timer. Fires once after `autoRevertMinutes` and
    /// reverts to Default. No-op when off or already on the default profile.
    private func armAutoRevert() {
        autoRevertTimer?.invalidate()
        autoRevertTimer = nil
        guard autoRevertMinutes > 0, activeProfile.id != "silent" else { return }

        let minutes = autoRevertMinutes
        autoRevertTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes * 60), repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                TFLogger.shared.profile("Auto-revert: \(minutes)min elapsed — reverting to Default")
                self.resetAuto()
            }
        }
    }

    // MARK: - Heartbeat

    /// The daemon watchdog ignores heartbeats unless a manual fan command was
    /// sent, so hands-off (Silent) needs no heartbeat — running it there is a
    /// pure 5s wake on both processes for nothing. Run it only for fan-
    /// controlling profiles.
    private func syncHeartbeat(for profile: FanProfile) {
        if profile.curve.handsOff {
            stopHeartbeat()
        } else {
            startHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // Off the main thread — a blocking daemon round-trip must never stall the UI.
            DispatchQueue.global(qos: .utility).async {
                _ = try? DaemonClient().send("heartbeat")
            }
        }
        timer.tolerance = 1.0 // let the OS coalesce the wakeup
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastStatus = status
                // Publish-on-change, AND only while the panel is visible. The
                // dropdown's hosting view stays alive when hidden and re-renders
                // on every latestStatus change — so feeding it per-tick updates
                // while closed drives full SwiftUI layout for nothing.
                if self.menuOpen, self.latestStatus != status { self.latestStatus = status }
                if self.activeProfile != profile { self.activeProfile = profile }
                if self.monitorState != state {
                    self.monitorState = state
                    // Once the override clears on a hands-off profile, the
                    // heartbeat is no longer needed.
                    if state != .safetyOverride, self.activeProfile.curve.handsOff {
                        self.stopHeartbeat()
                    }
                }
                // The 95°C safety override sends a one-shot manual `setMax` even
                // on the hands-off Silent default, where the heartbeat is
                // otherwise stopped. The daemon watchdog reverts manual control
                // after 15s without a heartbeat, so the emergency fan-max would be
                // silently undone while still ≥95°C. Keep the heartbeat alive for
                // the WHOLE duration of the override — UNCONDITIONALLY, not just on
                // the leading edge: a profile switch during an override resets the
                // monitor's internal state without an onUpdate, so the next
                // re-assert can arrive with monitorState already == .safetyOverride
                // and would skip a transition-gated start. startHeartbeat() no-ops
                // when already running.
                if state == .safetyOverride {
                    self.startHeartbeat()
                }
                // Peak across all displayed CPU and GPU sensors for the menu bar.
                // Quantize to whole degrees: the label shows an integer, so a
                // jittering 0.1° fraction would otherwise force a relayout (CA
                // transaction) every update for a number that never changes.
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                let newMax = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
                    .map { $0.rounded() }
                if self.maxTemp != newMax { self.maxTemp = newMax }
                // Peak fan RPM, maintained every tick (independent of the menu
                // visibility gate) so the menu-bar label can show it on demand.
                let newRPM = status.fans.map(\.actualRPM).max()
                if self.maxFanRPM != newRPM { self.maxFanRPM = newRPM }
            }
        }
        // Fan commands run off the main thread, coalesced. The ramp fires
        // ~10×/s and each daemon round-trip can exceed 0.5s; routing this
        // through the main actor (as before) starved the UI run loop and froze
        // the app on profile switch.
        let executor = self.executor
        monitor.onFanCommand = { command in
            executor.submit(command)
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Menu visibility

    /// Called when the dropdown panel becomes visible: resume live updates and
    /// push the latest snapshot immediately so it isn't stale on open.
    func menuDidOpen() {
        menuOpen = true
        if let status = lastStatus, latestStatus != status { latestStatus = status }
    }

    /// Called when the panel is dismissed: stop feeding the hidden hosting view.
    func menuDidClose() {
        menuOpen = false
    }

    // MARK: - Actions

    func setSmart() {
        applyProfile(.smart)
    }

    /// One-tap "Max Fans Now" (feature request #21): drive all fans to maximum
    /// immediately, independent of the temperature-gated profile logic that
    /// makes the Max *profile* hold off until ~65°C (issue #10). The instant
    /// `.setMax` is sent now so fans jump even on a cool machine; switching to
    /// the Max profile then maintains them and keeps the heartbeat alive.
    func maxFansNow() {
        applyProfile(.max)
        // Coalesced channel (same as the monitor): lands after applyProfile's
        // reset above instead of racing it, and never blocks the UI thread.
        executor.submit(.setMax)
        TFLogger.shared.profile("Max Fans Now — all fans to maximum")
    }

    func resetAuto() {
        autoRevertTimer?.invalidate()
        autoRevertTimer = nil
        // Coalesced + off-thread so a stuck daemon can't freeze the UI.
        executor.submit(.resetAuto)
        baseProfile = .silent
        activeProfile = .silent
        monitor?.switchProfile(.silent)
        stopHeartbeat()
        TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
    }

    func selectProfile(_ profile: FanProfile) {
        applyProfile(profile)
    }

    /// Apply a base profile, transforming it through Extra Cool when enabled.
    /// `Silent` is hands-off and ignores Extra Cool.
    private func applyProfile(_ base: FanProfile) {
        baseProfile = base
        activeProfile = base
        let effective = extraCool ? base.extraCool() : base
        monitor?.switchProfile(effective)
        syncHeartbeat(for: effective)

        let cool = (extraCool && !base.curve.handsOff) ? " (Extra Cool)" : ""
        TFLogger.shared.profile("Selected: \(base.name)\(cool)")

        // Reset the hardware to auto on every (re)apply. switchProfile() above
        // resets the monitor's fan state to "off", so without this the daemon
        // could keep the fans at a stale manual RPM while the monitor believes
        // they are off — e.g. when toggling Extra Cool shifts the start
        // threshold past the current temperature. tick() re-engages within one
        // cycle, so the only cost is a brief return to Apple's curve.
        // Routed through the coalesced channel (same as the monitor) so a
        // slow/stuck daemon can't stall the profile switch on the main thread,
        // and a late monitor tick can't overtake this reset.
        executor.submit(.resetAuto)

        // (Re)arm the auto-revert timer for the newly applied profile. Routing
        // this through applyProfile() covers both Smart and explicit selection;
        // it is a no-op for Default (Silent).
        armAutoRevert()
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        // Reverting the toggle in the catch below re-fires this didSet. Without
        // this guard, a persistently throwing SMAppService recurses until the
        // stack overflows (SIGSEGV). The guard makes the revert a no-op re-entry.
        guard !isUpdatingLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            isUpdatingLoginItem = true
            launchAtLogin = !launchAtLogin // revert toggle (guarded against re-entry)
            isUpdatingLoginItem = false
        }
    }
}
