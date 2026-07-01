//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import SwiftUI
import ThermalForgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }

        offerDaemonSetupIfNeeded()
    }

    /// First-run helper: if the privileged fan-control daemon isn't installed
    /// yet, offer to install it once (one admin prompt). Subsequent launches
    /// rely on the in-menu setup banner instead of nagging.
    private func offerDaemonSetupIfNeeded() {
        guard !DaemonInstaller.isInstalled else { return }
        let offeredKey = "didOfferDaemonInstall"
        guard !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set up ThermalForge fan control"
        alert.informativeText = "ThermalForge installs a small background service to control your "
            + "fans. macOS will ask for your password once. You can also do this later from the "
            + "menu-bar dropdown."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = DaemonInstaller.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset fans on quit so daemon doesn't hold stale manual settings
        let client = DaemonClient()
        try? client.execute(.resetAuto)
    }
}

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel(
                state: appState.monitorState,
                display: appState.menuBarDisplay,
                maxTemp: appState.maxTemp,
                maxFanRPM: appState.maxFanRPM,
                fahrenheit: appState.useFahrenheit
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    var display: MenuBarDisplay = .temperature
    let maxTemp: Float?
    var maxFanRPM: Int? = nil
    var fahrenheit: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            switch display {
            case .temperature:
                if let tempC = maxTemp {
                    let value = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                    Text("\(Int(value))°")
                        .font(.system(.caption, design: .monospaced))
                }
            case .fanSpeed:
                if let rpm = maxFanRPM {
                    Text("\(rpm)")
                        .font(.system(.caption, design: .monospaced))
                }
            case .iconOnly:
                EmptyView()
            }
        }
    }

    private var iconName: String {
        switch state {
        case .safetyOverride: return "exclamationmark.triangle.fill"
        case .active: return "fan.fill"
        case .idle: return "fan"
        }
    }
}
