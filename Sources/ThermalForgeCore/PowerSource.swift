//
//  PowerSource.swift
//  ThermalForge
//
//  Reads the current power source (AC adapter vs battery) via IOKit. Telemetry
//  only — logged for tuning; it does NOT change fan behavior. (Any future
//  battery ease-off would be opt-in and default-off.)
//

import Foundation
import IOKit.ps

public enum PowerSource: String, Sendable {
    case ac
    case battery
    case unknown

    /// The source currently powering the machine.
    public static var current: PowerSource {
        // IOPSCopyPowerSourcesInfo returns a snapshot we own (Copy → retained).
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        // IOPSGetProvidingPowerSourceType returns a value we do NOT own (Get →
        // unretained) — taking it retained would over-release.
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?
            .takeUnretainedValue() as String? else {
            return .unknown
        }
        switch type {
        case kIOPSACPowerValue: return .ac
        case kIOPSBatteryPowerValue: return .battery
        default: return .unknown
        }
    }
}
