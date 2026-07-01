# Changelog

## Community integration (marxo126 fork)

This fork merges the valuable open pull requests and fork work that upstream
(`ProducerGuy/ThermalForge`) had not merged, plus fixes for several open issues.
Every change was applied on top of the `PR #16` performance/structural
refactor, builds cleanly on Swift 6.3.2, and passes the test suite (45 tests).
Original authorship is preserved on each integrated change.

### Improved thermal logging & stats

The `log` command previously wrote only raw per-sample CSVs — you had to
post-process them yourself. Now every session also gets computed statistics:

- **`summary.json` + `summary.txt`** written on finish: duration, sample count,
  per-fan RPM min/avg/max (and average % of the fan's ceiling), CPU/GPU peak &
  average, and every sensor's min/avg/max ranked by peak.
- **`thermalforge log`** prints that summary when it finishes.
- **New `thermalforge stats [path]`** command: prints the summary for a past
  session (the most recent by default) without re-running a log.
- Stats math lives in a standalone, unit-tested `LogStatsAccumulator`
  (streaming, O(1) memory per key). Verified on M4 Max.

### First-run installer + DMG

- **In-app daemon setup:** the menu-bar app now installs the privileged
  fan-control daemon itself — a first-run prompt and an in-menu "Install
  fan-control daemon" banner run the bundled `thermalforge install` with one
  standard macOS admin prompt (no terminal needed). Strips quarantine via an
  absolute `/usr/bin/xattr` (a bare name could resolve to an attacker binary run
  as root), and inherits the hardened `install` (root-owned-dir guard + rollback).
- **DMG installer:** `Scripts/build-dmg.sh` produces a drag-to-Applications
  `ThermalForge.dmg` (menu-bar `.app` + bundled CLI). Unsigned — first launch is
  right-click → Open.

### Integrated pull requests & fork work

| Source                                           | What it does                                                                                                                                                                                                                                                                                           | Resolves               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- |
| **PR #16** — Artem Bambalov (`@arttttt`)         | Perf/structural foundation: fixes the profile-switch UI freeze, a multi-GB daemon memory leak (`autoreleasepool`), and cuts idle CPU ~9% → ~0.3% (adaptive poll cadence, `CommandCoalescer`, per-key SMC size cache, `@Observable` migration, client socket timeouts).                                 | freeze, leak, idle CPU |
| **PR #13** — Jakub Dudek (`@alcides-collective`) | Hardens the privileged daemon socket: moves it to root-owned `/var/run`, authenticates every peer via `LOCAL_PEERCRED` (only root + the active console user), re-reading the console UID per connection (self-heals across reboot/fast-user-switch). Closes an unauthenticated local fan-control hole. | local control hole     |
| **AlexMorrissey-Smith fork** (salvaged)          | `AppState` `launchAtLogin` re-entrancy guard — prevents a stack-overflow (SIGSEGV) when `SMAppService` throws persistently.                                                                                                                                                                            | crash                  |
| **PR #15** — Jakub Dudek (`@alcides-collective`) | "Extra Cool" profile modifier (colder, louder, faster) + `--extra-cool` CLI flag, with tests.                                                                                                                                                                                                          | —                      |
| **PR #18** — `@VlatkoMilisav`                    | Auto-revert timer (Off/15/30/60 min) that falls back to the Default profile.                                                                                                                                                                                                                           | #17                    |
| **PR #24** — Simon Bach (`@bachjessen`)          | `setup.sh`: replace the `xattr -r` form that newer macOS rejects (the committed 2,136-line SMC key-dump artifact in that PR was **excluded**).                                                                                                                                                         | install on new macOS   |

### New fixes for open issues (no upstream PR existed)

| Issue   | Fix                                                                                                                                                                                          |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **#21** | "Max Fans Now" one-tap menu action + `AppState.maxFansNow()` — instant max independent of the temperature-gated Max-profile logic.                                                           |
| **#20** | Menu-bar display modes (Temperature / Fan speed / Icon only), persisted.                                                                                                                     |
| **#22** | CLI `max`/`set`/`auto` route through the now-authenticated daemon first, so a sudo-less invocation by the logged-in user works instantly instead of stalling ~10s on a privileged SMC write. |
| **#4**  | Install prefix is overridable via `THERMALFORGE_PREFIX` (with a root-ownership safety check on the daemon path).                                                                             |
| **#9**  | Default profile pinned to Silent (hands-off) with a test.                                                                                                                                    |
| **#6**  | `[Compat] Mac16,5 M4 Max` — **verified working** on real M4 Max hardware (2 fans detected, valid RPM/min/max).                                                                               |

### Post-integration review fixes

- **Privilege escalation (install):** the root daemon could be launched from a
  user-writable directory under a custom/Homebrew prefix. The installed binary
  is now `chown root:wheel 0755` and install refuses to register the daemon
  unless its directory is root-owned and not user-writable.
- **Thermal safety:** the 95 °C emergency fan-max was being reverted by the
  daemon watchdog after 15 s on the hands-off Silent profile (no heartbeat). The
  heartbeat is now kept alive while the safety override is active.

### Deliberately dropped (with reason)

| Candidate                    | Why dropped                                                                                                                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| PR #2 (M5 Max fan detection) | Premise empirically disproven; **withdrawn by its own author** (the maintainer confirmed fan detection works on that M5 Max). Would have _masked_ transient read errors.                         |
| PR #11 / `arthur-hsu` fork   | Subset of PR #16 with an unsynchronized SMC cache; the fork also carried a branding-only README change. PR #16 supersedes it.                                                                    |
| PR #14                       | **Self-closed** by its author in favor of PR #16.                                                                                                                                                |
| PR #1 / `mileadev` fork      | Caches the console UID at daemon init → the menu-bar app is locked out after every reboot; the v2 rewrite is mutually exclusive with the PR #16 foundation. PR #13 hardening is strictly better. |

### Not addressed here

- **#3** (release tarball missing `Scripts/` + iconset) — release/packaging infra
  in `producerguy/tap`; no release workflow exists in this repo to fix/test.
- Compat **#5** (M3 Max), **#7** (M4 Pro mini), **#8**/**#23** (M5), **#19**
  (M2 Pro) — could not be reproduced on the available M4 Max hardware. No
  speculative SMC code was added (that is exactly what made PR #2 unsound).
