# System Monitor Lanes

A KDE Plasma 6 widget that brings back **classic separated-lane sparkline graphs** for CPU monitoring — one lane per core, with individual sparklines showing real-time utilization.

Replaces Plasma 6's default stacked/rainbow CPU charts with a layout that lets you instantly see what every core and thread is doing.

> Vibe coded with ❤️ by **John Boero** & **Claude**

## Features

- **Per-core sparkline lanes** — every physical core and hyperthread gets its own horizontal lane with a scrolling history graph
- **P/E/LP core detection** — Intel hybrid CPUs (Alder Lake, Raptor Lake, Meteor Lake) show Performance, Efficiency, and Low-Power cores in labeled groups with proportional lane heights
- **Hyperthreading awareness** — HT siblings are grouped under their physical core with distinct styling
- **Multi-socket support** — dual (or more) CPU systems display sockets as side-by-side columns, each filling the full panel height
- **Frequency-weighted utilization** — a core running 100% busy at 2 GHz base clock shows ~55% when its turbo max is 3.6 GHz, reflecting actual compute throughput rather than scheduler busy time
- **Turbo boost visualization** — when turbo pushes above rated max frequency, the graph scales beyond 100% with a dashed reference line at the 100% mark
- **Temperature sparkline** — per-socket temperature lane with blue→green→red color gradient responding to current temperature
- **Gradient fills** — sparkline area fills fade from opaque at the line to transparent at the baseline
- **Synchronized scrolling** — all lanes scroll at exactly the same rate via 1-second timer-based sampling, so temperature spikes correlate visually with load spikes
- **Configurable** — history duration (10–600s), label/value visibility, native KDE color pickers for all lane colors, adjustable hot threshold

## Screenshots

*(coming soon)*

## Requirements

- KDE Plasma 6.0+
- `ksystemstats` daemon (ships with Plasma)
- `QML_XHR_ALLOW_FILE_READ=1` environment variable (for full CPU topology detection)

## Installation

### From source

```bash
git clone https://github.com/jboero/system-monitor-lanes.git
cd system-monitor-lanes
kpackagetool6 -i . -t Plasma/Applet
```

### Upgrade

```bash
kpackagetool6 -r org.kde.plasma.systemmonitor.lanes -t Plasma/Applet 2>/dev/null
rm -rf ~/.local/share/plasma/plasmoids/org.kde.plasma.systemmonitor.lanes
rm -rf ~/.cache/plasmashell/qmlcache/*
cd system-monitor-lanes
kpackagetool6 -i . -t Plasma/Applet
```

### Setting the environment variable

For accurate CPU topology detection (core types, sockets, hyperthreading, max frequency), QML needs permission to read `/sys` files. Add to `/etc/environment`:

```
QML_XHR_ALLOW_FILE_READ=1
```

Then restart Plasma (`plasmashell --replace &` or log out and back in).

Without this variable the widget falls back to a basic sequential core list — it still works, but without P/E grouping, socket detection, or frequency-weighted usage. The widget displays a notice in both the main view and the settings dialog when this variable is not set.

## Usage

1. Right-click your desktop or panel → **Add Widgets**
2. Search for **System Monitor Lanes**
3. Add to panel or desktop

### Testing with plasmoidviewer

```bash
QML_XHR_ALLOW_FILE_READ=1 plasmoidviewer -a org.kde.plasma.systemmonitor.lanes
```

## Configuration

Right-click the widget → **Configure**:

| Setting | Description |
|---|---|
| **Title** | Custom title, or leave blank for "CPU Load Monitor" |
| **History (sec)** | Sparkline scroll duration, 10–600 seconds |
| **Show labels / values** | Toggle core name labels and percentage readouts |
| **Proportional heights** | P-cores get taller lanes than E-cores |
| **Frequency-weighted usage** | Scale reported usage by current/max frequency ratio |
| **Temperature heatmap** | Enable per-socket temperature sparkline lane |
| **Hot threshold** | Temperature (°C) at which the color reaches red |
| **Colors** | Native KDE color pickers for P-core line/fill, thread line/fill, and hot color |

## How it works

### Topology detection

On startup the widget fires XMLHttpRequests against `/sys/devices/system/cpu/cpu*/topology/` to discover physical cores, hyperthreads, sockets, and core types. Core classification uses the ratio of each core's `cpuinfo_max_freq` to the global maximum:

| Ratio | Type | Lane weight |
|---|---|---|
| ≥ 0.85 | P-core | 1.0 |
| 0.60 – 0.85 | E-core | 0.7 |
| < 0.60 | LP E-core | 0.4 |

If `/sys` is unavailable (XHR blocked), a 3-second safety timer triggers fallback mode using the `cpu/all/coreCount` sensor.

### Frequency-weighted utilization

```
effectiveUsage = reportedUsage × (currentFreq / maxFreq)
```

`maxFreq` comes from sysfs `cpuinfo_max_freq` when available. On systems where cpufreq isn't exposed (common on Xeons), the widget falls back to the **peak frequency observed** from the live `cpu/cpuN/frequency` sensor — which auto-calibrates upward as cores turbo boost. When turbo pushes effective usage above 100%, the Y-axis expands with a dashed reference line at the 100% mark.

### Synchronized sampling

All lanes (CPU usage and temperature) use a 1-second `Timer` to sample the latest sensor value into history, rather than pushing on each `onValueChanged` event. This guarantees all sparklines scroll in lockstep regardless of how frequently individual sensors update.

## Project structure

```
system-monitor-lanes/
├── metadata.json                    # Plasma 6 package metadata (v1.0.0)
├── contents/
│   ├── config/
│   │   ├── main.xml                 # KConfigXT schema
│   │   └── config.qml               # ConfigModel registration
│   └── ui/
│       ├── main.qml                 # Root PlasmoidItem, /sys topology reader, lane builder
│       ├── CpuLaneItem.qml          # CPU sparkline lane with freq-weighted usage
│       ├── TempLaneItem.qml         # Temperature sparkline with gradient coloring
│       └── ConfigGeneral.qml        # Settings dialog
├── README.md
└── PROMPT.md                        # Development context & architecture notes
```

## Tested hardware

- **Intel Core Ultra 7 155H (Meteor Lake)** — 22 logical CPUs: 6 P-cores (HT) + 8 E-cores + 2 LP E-cores, active cpufreq
- **Dual Intel Xeon E5-2696 v4 (Broadwell-EP)** — 88 logical CPUs: 2 sockets × 22 cores × 2 threads, no cpufreq driver, turbo boost via observed frequency

## License

GPLv3 — see [LICENSE](LICENSE) file for full text.
