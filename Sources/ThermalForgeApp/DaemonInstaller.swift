//
//  DaemonInstaller.swift
//  ThermalForge
//
//  First-run helper: install the privileged fan-control daemon straight from
//  the menu-bar app (one standard macOS admin prompt) instead of requiring the
//  user to run `sudo thermalforge install` in a terminal.
//

import Foundation
import ThermalForgeCore

@MainActor
enum DaemonInstaller {
    /// The `thermalforge` CLI/daemon binary shipped inside the .app bundle
    /// (Contents/Resources/thermalforge). Present in DMG/`setup.sh` builds.
    static var bundledBinary: String? {
        Bundle.main.url(forResource: "thermalforge", withExtension: nil)?.path
    }

    /// The launchd daemon has been installed (its plist is present).
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: ThermalForgeDaemon.plistPath)
    }

    /// The daemon is installed AND currently accepting connections.
    static var isRunning: Bool { ThermalForgeDaemon.isRunning }

    enum Result: Equatable {
        case installed
        case cancelled
        case failed(String)
        case noBundledBinary
    }

    /// Install the daemon by running the bundled `thermalforge install` with
    /// administrator privileges (one auth prompt). Quarantine is stripped first
    /// so the unsigned binary can be launched by launchd. Blocks on the modal
    /// auth dialog — call from a user action on the main actor.
    static func install() -> Result {
        guard let binary = bundledBinary else { return .noBundledBinary }

        // Escape the path for embedding in the AppleScript source *string*; the
        // shell-level quoting is delegated to AppleScript's `quoted form of`.
        let asPath = binary
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let quoted = "quoted form of \"\(asPath)\""
        // Strip quarantine, then install — both as root, one prompt.
        // `xattr` MUST be an absolute path: `do shell script` inherits the
        // caller's PATH, so a bare name could resolve to an attacker's binary in
        // a user-writable PATH dir and run it as root (local priv-esc). The
        // install target itself is already an absolute, shell-quoted path.
        let source = """
            do shell script ("/usr/bin/xattr -dr com.apple.quarantine " & \(quoted) & \
            " 2>/dev/null; " & \(quoted) & " install") with administrator privileges
            """

        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { return .cancelled } // user dismissed the auth prompt
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Installation failed."
            return .failed(msg)
        }
        return isInstalled ? .installed : .failed("Installer finished but the daemon is not present.")
    }
}
