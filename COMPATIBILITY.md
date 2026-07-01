# Hardware Compatibility

Verified fan-control and test results for this fork. Each entry records real,
reproducible data (read-only `thermalforge status` / `thermalforge discover`,
plus the `swift test` suite) on actual hardware — **not** speculative support.

To contribute: run the read-only commands below on your Mac and open a PR adding
a row. No `sudo` and no fan control is needed to gather this — reads are unprivileged.

```bash
swift build -c release
.build/release/thermalforge status      # fan RPMs + temperatures (JSON)
.build/release/thermalforge discover    # full SMC key dump
swift test                              # test suite
```

## Verified

| Machine (model id)      | Chip         | macOS           | Fans detected | Min→Max RPM | SMC keys | Tests    | Verified   |
| ----------------------- | ------------ | --------------- | ------------- | ----------- | -------- | -------- | ---------- |
| MacBook Pro (`Mac16,5`) | Apple M4 Max | 26.4.1 (25E253) | 2             | 1350 → 5777 | 3384     | 45/45 ✅ | 2026-07-01 |

### `Mac16,5` — Apple M4 Max — details (resolves issue #6)

Fan control detects both fans correctly and reports valid limits; all temperature
sensors read. Confirms this fork works out-of-box on the M4 Max reported in
issue **#6 `[Compat] Mac16,5 M4 Max`**.

```json
{
  "fans": [
    {
      "index": 0,
      "actual_rpm": 1347,
      "target_rpm": 1350,
      "min_rpm": 1350,
      "max_rpm": 5777,
      "mode": "auto"
    },
    {
      "index": 1,
      "actual_rpm": 1461,
      "target_rpm": 1458,
      "min_rpm": 1350,
      "max_rpm": 5777,
      "mode": "auto"
    }
  ]
}
```

- **Temperature sensors read:** 22 (incl. `TCMb` CPU ≈ 64.5 °C, `Tg05` GPU ≈ 58.6 °C).
- **SMC keys enumerated:** 3384.
- **Test suite:** 45 tests in 6 suites, all passing (Swift 6.3.2 / Xcode 26.5).
- **Method:** read-only status + discover; no fan-control writes and no daemon
  install were performed during verification.

## Not yet verified

The following compat reports could not be reproduced on the available hardware
(only an M4 Max was on hand). No speculative SMC code was added for them — that
is exactly what made the withdrawn PR #2 unsound. Please contribute results:

- `#5` Mac (M3 Max) · `#7` Mac mini (M4 Pro) · `#8` `Mac17,7` (M5 Max) ·
  `#23` `Mac17,8` (M5 Pro) · `#19` MacBook Pro (M2 Pro, 2023 14")
