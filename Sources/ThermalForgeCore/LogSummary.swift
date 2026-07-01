//
//  LogSummary.swift
//  ThermalForge
//
//  Computed statistics for a thermal-log session. Turns the raw per-sample CSV
//  into an at-a-glance summary (per-sensor min/avg/max, per-fan RPM stats,
//  CPU/GPU peaks). Streaming accumulator so it costs O(1) memory per key.
//

import Foundation

// MARK: - Summary model

public struct LogSummary: Codable, Equatable {
    public struct SensorStat: Codable, Equatable {
        public let key: String
        public let min: Double
        public let avg: Double
        public let max: Double
    }

    public struct FanStat: Codable, Equatable {
        public let index: Int
        public let minRPM: Int
        public let avgRPM: Int
        public let maxRPM: Int
        /// Average RPM as a percentage of the fan's hardware ceiling (0 if unknown).
        public let pctOfCeiling: Double
    }

    public let durationSeconds: Double
    public let samples: Int
    public let sampleRateHz: Double
    public let fans: [FanStat]
    public let cpuPeakC: Double
    public let cpuAvgC: Double
    public let gpuPeakC: Double
    public let gpuAvgC: Double
    /// Sensors ranked by peak temperature (hottest first).
    public let hottestSensors: [SensorStat]
    /// Every sensor, sorted by key — full detail.
    public let allSensors: [SensorStat]
}

// MARK: - Streaming accumulator

/// Feeds one sample at a time and produces a `LogSummary`. Kept separate from
/// `ThermalLogger` (which needs live hardware) so the stats math is unit-testable.
public final class LogStatsAccumulator {
    private struct Running {
        var min = Double.greatestFiniteMagnitude
        var max = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        mutating func add(_ v: Double) {
            if v < min { min = v }
            if v > max { max = v }
            sum += v
            count += 1
        }
        var avg: Double { count > 0 ? sum / Double(count) : 0 }
    }

    /// CPU sensors on Apple Silicon are prefixed TC / Tp; GPU are TG / Tg.
    public static let cpuPrefixes = ["TC", "Tp"]
    public static let gpuPrefixes = ["TG", "Tg"]

    private var sensors: [String: Running] = [:]
    private var fans: [Int: Running] = [:]
    private var cpu = Running()
    private var gpu = Running()
    private(set) public var sampleCount = 0

    public init() {}

    /// Add one sample: `fans` = (index, rpm) pairs, `temps` = sensor-key → °C.
    public func add(fans fanSamples: [(index: Int, rpm: Int)], temps: [String: Double]) {
        sampleCount += 1

        for (index, rpm) in fanSamples {
            fans[index, default: Running()].add(Double(rpm))
        }

        for (key, temp) in temps {
            sensors[key, default: Running()].add(temp)
        }

        if let cpuMax = peak(of: temps, prefixes: Self.cpuPrefixes) { cpu.add(cpuMax) }
        if let gpuMax = peak(of: temps, prefixes: Self.gpuPrefixes) { gpu.add(gpuMax) }
    }

    private func peak(of temps: [String: Double], prefixes: [String]) -> Double? {
        temps
            .filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
            .values.max()
    }

    /// Build the summary. `fanCeilingRPM` = hardware max RPM (for pctOfCeiling).
    public func summary(durationSeconds: Double, sampleRateHz: Double, fanCeilingRPM: Int) -> LogSummary {
        let fanStats: [LogSummary.FanStat] = fans.keys.sorted().map { index in
            let r = fans[index]!
            let avg = Int(r.avg.rounded())
            let pct = fanCeilingRPM > 0 ? (r.avg / Double(fanCeilingRPM) * 100).rounded() / 1 : 0
            return LogSummary.FanStat(
                index: index,
                minRPM: Int(r.min.rounded()),
                avgRPM: avg,
                maxRPM: Int(r.max.rounded()),
                pctOfCeiling: pct
            )
        }

        let sensorStats: [LogSummary.SensorStat] = sensors.keys.sorted().map { key in
            let r = sensors[key]!
            return LogSummary.SensorStat(
                key: key,
                min: (r.min * 10).rounded() / 10,
                avg: (r.avg * 10).rounded() / 10,
                max: (r.max * 10).rounded() / 10
            )
        }
        let hottest = sensorStats.sorted { $0.max > $1.max }

        return LogSummary(
            durationSeconds: (durationSeconds * 10).rounded() / 10,
            samples: sampleCount,
            sampleRateHz: sampleRateHz,
            fans: fanStats,
            cpuPeakC: cpu.count > 0 ? (cpu.max * 10).rounded() / 10 : 0,
            cpuAvgC: cpu.count > 0 ? (cpu.avg * 10).rounded() / 10 : 0,
            gpuPeakC: gpu.count > 0 ? (gpu.max * 10).rounded() / 10 : 0,
            gpuAvgC: gpu.count > 0 ? (gpu.avg * 10).rounded() / 10 : 0,
            hottestSensors: Array(hottest.prefix(5)),
            allSensors: sensorStats
        )
    }
}

// MARK: - Human-readable rendering

public extension LogSummary {
    /// A compact plain-text report (written to summary.txt and printed on finish).
    func plainText() -> String {
        var out = ""
        out += "ThermalForge — session summary\n"
        out += String(repeating: "─", count: 44) + "\n"
        let mins = durationSeconds / 60
        out += String(format: "Duration:  %.1f min (%.0f s), %d samples @ %.2f Hz\n",
                      mins, durationSeconds, samples, sampleRateHz)
        out += String(format: "CPU:       peak %.1f°C   avg %.1f°C\n", cpuPeakC, cpuAvgC)
        out += String(format: "GPU:       peak %.1f°C   avg %.1f°C\n", gpuPeakC, gpuAvgC)
        out += "\nFans (RPM):\n"
        for f in fans {
            out += String(format: "  Fan %d:   min %d   avg %d   max %d   (avg %.0f%% of ceiling)\n",
                          f.index, f.minRPM, f.avgRPM, f.maxRPM, f.pctOfCeiling)
        }
        out += "\nHottest sensors (peak °C):\n"
        for s in hottestSensors {
            out += String(format: "  %-6@  min %.1f   avg %.1f   max %.1f\n",
                          s.key as NSString, s.min, s.avg, s.max)
        }
        return out
    }
}
