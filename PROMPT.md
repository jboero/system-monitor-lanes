# System Monitor Lanes — KDE Plasma 6 Widget

## Plugin ID
`org.kde.plasma.systemmonitor.lanes`

## Overview
A standalone KDE Plasma 6 widget that restores **KDE4/5-style separated-lane sparkline graphs** for CPU monitoring. Each CPU core/thread gets its own horizontal lane with an individual sparkline. Replaces the KDE6 "stacked rainbow" charts that make it impossible to identify individual core behavior.

**Key feature**: frequency-weighted CPU utilization. When a core reports 100% usage but is running at 2 GHz (max turbo 3.6 GHz), the widget shows ~55% — reflecting actual compute throughput rather than scheduler busy percentage. Turbo boost above rated capacity is shown as >100% with a dashed reference line.

## Current Version: 1.0.0

## File Structure
```
system-monitor-lanes/
├── metadata.json                    # Plasma 6 metadata (KPackageStructure)
├── LICENSE                          # GPLv3
├── README.md                        # User-facing documentation
├── PROMPT.md                        # Developer/AI context document
├── contents/
│   ├── config/
│   │   ├── main.xml                 # KConfigXT schema
│   │   └── config.qml               # ConfigModel (QML)
│   └── ui/
│       ├── main.qml                 # Root PlasmoidItem, /sys reader, lane list builder
│       ├── CpuLaneItem.qml          # CPU sparkline lane with gradient fill
│       ├── TempLaneItem.qml         # Temperature sparkline with blue→green→red gradient
│       └── ConfigGeneral.qml        # Settings UI with color pickers
```

## Architecture

### Sensor Data Source
- Uses `org.kde.ksysguard.sensors` QML module (`Sensors.Sensor`)
- Daemon: `ksystemstats` — D-Bus name `org.kde.ksystemstats1`
- Sensors update asynchronously; a 1-second Timer in each lane item samples the last-known value to ensure synchronized scroll rates across all lanes

### Sensor ID Patterns
```
cpu/cpu{N}/usage              - per-core utilization %
cpu/cpu{N}/frequency          - current frequency MHz
cpu/all/coreCount             - total logical CPU count
cpu/all/averageTemperature    - package average temperature
```

**IMPORTANT**: `cpu/all/cpuCount` returns sockets, not cores. Use `cpu/all/coreCount`.
**MISSING**: `cpu/cpu{N}/maximumFrequency` does not exist. Max frequency comes from `/sys`.

### /sys Filesystem Reads
Requires `QML_XHR_ALLOW_FILE_READ=1` environment variable.

| Path | Returns | Purpose |
|------|---------|---------|
| `.../topology/thread_siblings_list` | e.g. "0,44" | HT detection |
| `.../topology/physical_package_id` | e.g. "0" or "1" | Socket assignment |
| `.../cpufreq/cpuinfo_max_freq` | e.g. "4800000" (kHz) | P/E/LP classification |

When XHR is blocked, widget falls back to basic sequential mode using `coreCount` sensor. A 3-second safety timer detects silently-dropped XHR callbacks.

### CPU Discovery & Classification
1. Fire 128×3 XMLHttpRequests (siblings, package_id, max_freq)
2. Group CPUs by physical core via shared `thread_siblings_list`
3. Classify by frequency ratio: P-core (≥85%), E-core (60-85%), LP-core (<60%)
4. Sort by socket → core type → index
5. Build lane list with per-socket temp lanes and section headers

### Multi-Socket Layout
When multiple sockets are detected, lanes are split into side-by-side columns — one per socket, equally dividing the widget width. Each socket column independently fills the panel height with its own proportional lane sizing.

### Frequency-Weighted Utilization
```
effectiveUsage = reportedUsage × (currentFreq / maxFreq)
```
- `maxFreq` prefers sysfs `cpuinfo_max_freq`; falls back to peak observed sensor frequency
- When turbo boost pushes above rated max, usage exceeds 100% — the Y-axis auto-scales with a dashed 100% reference line

### Lane Height Weights
```
P-core: 1.0    E-core: 0.7    LP-core: 0.4    Temp: 1.2
```

## Critical QML/Plasma 6 Gotchas

### metadata.json
- `"X-Plasma-API-Minimum-Version": "6.0"` at top level (outside KPlugin)
- `"KPackageStructure": "Plasma/Applet"` at top level
- Entry point is always `contents/ui/main.qml`

### ConfigGeneral.qml
- Root must be `Item` (not ScrollView/FormLayout) — Plasma embeds it into its own page
- Add `property string title` for Plasma's config page system
- Add `property var cfg_*Default` stubs for every config property
- Use `Flickable` inside the `Item` for scrolling; Plasma's own scroll container is unreliable in plasmoidviewer
- Use `KQControls.ColorButton` from `org.kde.kquickcontrols` for color pickers

### Sensors.Sensor
- `visible: false` on parent prevents sensor init — use `height: 0` + `clip: true`
- ksystemstats returns values for non-existent CPU IDs — cannot rely on "no data" for detection
- Different sensors fire at different rates — use Timer-based sampling for synchronized sparklines

### Canvas
- Always guard: `if (w < 2 || h < 2) return`
- Use `createLinearGradient` for fill-under-curve effects
- `ctx.reset()` before drawing to avoid stale state

### XMLHttpRequest
- Blocked by default in Qt6 — requires `QML_XHR_ALLOW_FILE_READ=1`
- May silently drop callbacks on some Qt builds — use a safety Timer to detect
- Guard `finalize()` against double-entry with a local flag

## Development Workflow
```bash
# Install/update
kpackagetool6 -r org.kde.plasma.systemmonitor.lanes -t Plasma/Applet 2>/dev/null
rm -rf ~/.local/share/plasma/plasmoids/org.kde.plasma.systemmonitor.lanes
rm -rf ~/.cache/plasmashell/qmlcache/*
kpackagetool6 -i . -t Plasma/Applet

# Test
QML_XHR_ALLOW_FILE_READ=1 plasmoidviewer -a org.kde.plasma.systemmonitor.lanes

# Watch errors
journalctl --user -u plasma-plasmashell -f | grep -i "qml\|error\|warn"
```

## Tested Hardware
- **Intel Core Ultra 7 155H** — 22 CPUs: 6 P-cores (HT) + 8 E-cores + 2 LP E-cores, intel_pstate
- **Dual Intel Xeon E5-2696 v4** — 88 CPUs: 2×22 cores ×2 threads, no cpufreq, turbo 3.6 GHz

## Version History
- **Pre-release**: Iterative development through internal versions 1.0–3.4
- **1.0.0**: First public release — multi-socket columns, XHR safety detection, observed-max-freq fallback, synchronized timer-based sampling, turbo >100% graphing, gradient fills, color picker config, GPLv3
