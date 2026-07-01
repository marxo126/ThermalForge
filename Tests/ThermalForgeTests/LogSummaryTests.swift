import Testing
@testable import ThermalForgeCore

@Suite("Log summary stats")
struct LogSummaryTests {
    @Test("Accumulates per-fan and per-sensor min/avg/max across samples")
    func accumulatesStats() {
        let acc = LogStatsAccumulator()
        acc.add(fans: [(index: 0, rpm: 1000), (index: 1, rpm: 2000)],
                temps: ["TC0P": 50, "TG0P": 40])
        acc.add(fans: [(index: 0, rpm: 2000), (index: 1, rpm: 4000)],
                temps: ["TC0P": 70, "TG0P": 60])

        let s = acc.summary(durationSeconds: 10, sampleRateHz: 1, fanCeilingRPM: 5000)

        #expect(s.samples == 2)
        #expect(s.durationSeconds == 10)

        // Fan 0: 1000 → 2000
        let fan0 = s.fans.first { $0.index == 0 }!
        #expect(fan0.minRPM == 1000)
        #expect(fan0.avgRPM == 1500)
        #expect(fan0.maxRPM == 2000)
        #expect(fan0.pctOfCeiling == 30) // 1500 / 5000

        // Fan 1: 2000 → 4000
        let fan1 = s.fans.first { $0.index == 1 }!
        #expect(fan1.avgRPM == 3000)
        #expect(fan1.pctOfCeiling == 60)

        // CPU sensors are TC/Tp; GPU are TG/Tg.
        #expect(s.cpuPeakC == 70)
        #expect(s.cpuAvgC == 60)  // (50 + 70) / 2
        #expect(s.gpuPeakC == 60)
        #expect(s.gpuAvgC == 50)  // (40 + 60) / 2

        // Hottest first by peak.
        #expect(s.hottestSensors.first?.key == "TC0P")
        #expect(s.hottestSensors.first?.max == 70)
    }

    @Test("Empty session yields zeroed stats, not a crash")
    func emptySession() {
        let s = LogStatsAccumulator().summary(durationSeconds: 0, sampleRateHz: 1, fanCeilingRPM: 0)
        #expect(s.samples == 0)
        #expect(s.fans.isEmpty)
        #expect(s.cpuPeakC == 0)
        #expect(s.hottestSensors.isEmpty)
    }
}
