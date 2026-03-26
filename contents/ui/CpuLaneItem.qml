import QtQuick
import org.kde.plasma.components as PlasmaComponents
import org.kde.ksysguard.sensors as Sensors

Item {
    id: lane

    property bool cpuMode: false
    property int cpuIndex: 0
    property string sensorId: ""
    property string label: ""
    property string unit: "%"
    property real maxValue: 100
    property int maxSamples: 60
    property bool showLabel: true
    property bool showValue: true
    property bool showFreqLine: false
    property int coreCount: 0
    property real totalWeight: 1
    property real availableHeight: 400
    property string coreType: "P"   // P, HT, E, LP
    property real weight: 1.0
    property bool sysReadFailed: false
    property bool freqWeighted: true // from config: scale usage by curFreq/maxFreq
    property real maxFreqKhz: 0    // from /sys cpuinfo_max_freq (in kHz)
    property int coreNum: 0       // primary CPU index for this physical core
    property bool isHT: false     // true if this is a hyperthread sibling
    property int htIndex: -1      // HT sibling index (0, 1, ...)

    property bool gotData: false
    property bool dead: false
    property real maxFreq: 0   // peak observed fallback (in MHz from sensor)
    property real curFreq: 0   // current frequency (MHz from sensor)

    // Last sensor value, updated asynchronously by sensor callback.
    // The 1-second sample timer reads this to push into history.
    property real lastRawValue: 0

    property var history: []
    property var freqHistory: []  // frequency as % of max, for second line graph
    property real observedMax: 1
    property real historyPeak: 100  // peak value in current history window (for CPU >100% scaling)
    property string displayValue: ""

    readonly property bool shouldHide: {
        if (cpuMode && coreCount > 0) return cpuIndex >= coreCount;
        return dead;
    }

    // -- Height: proportional share of available space ------------
    height: shouldHide ? 0 : Math.max(8, availableHeight * weight / Math.max(1, totalWeight))
    clip: true

    // -- Colors per core type -------------------------------------
    readonly property color lineColor: {
        if (coreType === "HT") return "#6a8ab8";
        if (coreType === "E")  return "#4a9a7a";
        if (coreType === "LP") return "#7a7a6a";
        return "#4da6ff";
    }
    readonly property color fillColor: {
        if (coreType === "HT") return "#2a3a4d";
        if (coreType === "E")  return "#264a3d";
        if (coreType === "LP") return "#3a3a30";
        return "#264d73";
    }
    // Parsed color object for gradient stops (Canvas needs r/g/b components)
    readonly property color fillColorObj: fillColor
    readonly property real labelOpacity: {
        if (coreType === "LP") return 0.45;
        if (coreType === "HT") return 0.55;
        if (coreType === "E")  return 0.7;
        return 0.85;
    }

    // -- Effective max frequency (MHz) for freq-weighted usage -----
    // Use only the static sysfs cpuinfo_max_freq as the authoritative max.
    readonly property real effectiveMaxMhz: {
        if (maxFreqKhz > 0) return maxFreqKhz / 1000;
        return 0;
    }

    // -- Sensors --------------------------------------------------
    // Usage sensor — just stash the latest value; sampling is timer-driven.
    Sensors.Sensor {
        sensorId: cpuMode ? ("cpu/cpu" + lane.cpuIndex + "/usage") : lane.sensorId
        enabled: !shouldHide
        onValueChanged: {
            if (!lane.gotData) { lane.gotData = true; graceTimer.stop(); }
            lane.lastRawValue = Number(value) || 0;
        }
    }

    // Current frequency sensor — always enabled for freq-weighted usage
    Sensors.Sensor {
        sensorId: cpuMode ? ("cpu/cpu" + lane.cpuIndex + "/frequency") : ""
        enabled: cpuMode && !shouldHide
        onValueChanged: {
            var f = Number(value) || 0;
            lane.curFreq = f;
            if (f > lane.maxFreq) lane.maxFreq = f;
        }
    }

    // -- 1-second sample timer (synchronized scroll rate) ----------
    Timer {
        id: sampleTimer
        interval: 1000; running: !shouldHide; repeat: true
        onTriggered: {
            if (!lane.gotData) return;  // wait for first sensor value

            var rawUsage = lane.lastRawValue;

            // Frequency-weighted usage: scale by curFreq / maxFreq, capped at 1.0
            var effectiveUsage = rawUsage;
            var maxMhz = lane.effectiveMaxMhz;
            if (lane.freqWeighted && cpuMode && curFreq > 0 && maxMhz > 0) {
                effectiveUsage = rawUsage * Math.min(1.0, curFreq / maxMhz);
            }

            lane.displayValue = effectiveUsage.toFixed(1) + "%";

            var h = lane.history.slice();
            h.push(effectiveUsage);
            if (h.length > lane.maxSamples) h.splice(0, h.length - lane.maxSamples);
            lane.history = h;

            // Track peak across current history window
            if (cpuMode) {
                var peak = 100;  // minimum ceiling is always 100%
                for (var i = 0; i < h.length; i++) if (h[i] > peak) peak = h[i];
                lane.historyPeak = peak;
            } else if (lane.maxValue < 0) {
                var peak2 = 1;
                for (var i2 = 0; i2 < h.length; i2++) if (h[i2] > peak2) peak2 = h[i2];
                lane.observedMax = lane.niceMax(peak2 * 1.1);
            }

            // Sample frequency as percentage of max for the second line graph
            if (lane.showFreqLine && cpuMode && maxMhz > 0) {
                var freqPct = (curFreq / maxMhz) * 100;
                var fh = lane.freqHistory.slice();
                fh.push(freqPct);
                if (fh.length > lane.maxSamples) fh.splice(0, fh.length - lane.maxSamples);
                lane.freqHistory = fh;
            }

            spark.requestPaint();
        }
    }

    Timer {
        id: graceTimer
        interval: 4000; running: !cpuMode; repeat: false
        onTriggered: { if (!lane.gotData) lane.dead = true; }
    }

    function fmtVal(v) {
        if (unit === "B/s" || unit === "bytes") return fmtBytes(v, unit === "B/s");
        if (unit === "%") return v.toFixed(0) + " %";
        return v.toFixed(1);
    }
    function fmtBytes(v, ps) {
        var s = ps ? "/s" : "";
        if (v < 1024) return v.toFixed(0)+" B"+s;
        if (v < 1048576) return (v/1024).toFixed(1)+" KiB"+s;
        if (v < 1073741824) return (v/1048576).toFixed(1)+" MiB"+s;
        return (v/1073741824).toFixed(1)+" GiB"+s;
    }
    function niceMax(v) {
        if (v <= 0) return 1;
        var e = Math.floor(Math.log10(v)), b = Math.pow(10,e), m = v/b;
        if (m<=1) return b; if (m<=2) return 2*b; if (m<=5) return 5*b; return 10*b;
    }

    // For CPU mode: minimum 100, but expands with 5% headroom if turbo pushes above
    readonly property real effectiveMax: {
        if (cpuMode) return Math.max(100, historyPeak * 1.05);
        return maxValue > 0 ? maxValue : observedMax;
    }

    // -- Layout ---------------------------------------------------
    // Value label on the right (outside the sparkline area)
    PlasmaComponents.Label {
        id: val
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.rightMargin: 4
        width: lane.showValue ? 55 : 0; visible: lane.showValue
        verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignRight
        text: lane.displayValue
        font.pixelSize: Math.max(7, Math.min(13, lane.height * 0.55))
        opacity: lane.labelOpacity
        z: 2
    }

    // Canvas spans full width behind labels for maximum graph area
    Canvas {
        id: spark
        anchors.left: parent.left; anchors.right: val.left
        anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.rightMargin: 2

        onWidthChanged: if (width > 0 && height > 0 && lane.history.length >= 2) requestPaint()
        onHeightChanged: if (width > 0 && height > 0 && lane.history.length >= 2) requestPaint()

        onPaint: {
            var w = width, h = height;
            if (w < 2 || h < 2) return;
            var ctx = getContext("2d");
            if (!ctx) return;
            ctx.reset(); ctx.clearRect(0, 0, w, h);

            var hist = lane.history;
            if (hist.length < 2) return;
            var eMax = lane.effectiveMax;
            if (eMax <= 0) eMax = 1;
            var samples = lane.maxSamples;
            var dx = w / Math.max(1, samples - 1);
            var ox = (samples - hist.length) * dx;

            // -- 100% reference line (dashed) when scale exceeds 100 --
            if (cpuMode && eMax > 105) {
                var refY = h - (100 / eMax) * (h - 1);
                ctx.beginPath();
                ctx.setLineDash([4, 3]);
                ctx.moveTo(0, refY);
                ctx.lineTo(w, refY);
                ctx.strokeStyle = "#ffffff";
                ctx.globalAlpha = 0.18;
                ctx.lineWidth = 1;
                ctx.stroke();
                ctx.setLineDash([]);
                ctx.globalAlpha = 1.0;
            }

            // -- Fill area under curve with gradient (opaque at line, transparent at bottom) --
            ctx.beginPath(); ctx.moveTo(ox, h);
            for (var i = 0; i < hist.length; i++) {
                var fy = h - (hist[i] / eMax) * (h - 1);
                ctx.lineTo(ox + i * dx, Math.max(0, fy));
            }
            ctx.lineTo(ox + (hist.length - 1) * dx, h); ctx.closePath();
            var grad = ctx.createLinearGradient(0, 0, 0, h);
            var baseAlpha = (coreType === "P") ? 0.45 : 0.35;
            grad.addColorStop(0, Qt.rgba(
                lane.fillColorObj.r, lane.fillColorObj.g, lane.fillColorObj.b, baseAlpha));
            grad.addColorStop(1, Qt.rgba(
                lane.fillColorObj.r, lane.fillColorObj.g, lane.fillColorObj.b, 0.0));
            ctx.fillStyle = grad;
            ctx.fill();

            // -- Stroke line --
            ctx.beginPath();
            for (var j = 0; j < hist.length; j++) {
                var px = ox + j * dx;
                var py = h - (hist[j] / eMax) * (h - 1);
                py = Math.max(0, py);
                if (j === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
            }
            ctx.strokeStyle = lane.lineColor;
            ctx.lineWidth = (coreType === "P") ? 1.2 : 0.8;
            ctx.lineJoin = "round"; ctx.stroke();

            // -- Frequency line (subtle gray, percentage of max) --
            var fHist = lane.freqHistory;
            if (lane.showFreqLine && cpuMode && fHist.length >= 2) {
                var fOx = (samples - fHist.length) * dx;
                ctx.beginPath();
                for (var f = 0; f < fHist.length; f++) {
                    var fpx = fOx + f * dx;
                    // freqHistory is 0-100% of max freq; map to same Y scale as usage
                    var fpy = h - (fHist[f] / eMax) * (h - 1);
                    fpy = Math.max(0, fpy);
                    if (f === 0) ctx.moveTo(fpx, fpy); else ctx.lineTo(fpx, fpy);
                }
                ctx.strokeStyle = "#888888";
                ctx.globalAlpha = 0.4;
                ctx.lineWidth = 0.8;
                ctx.lineJoin = "round"; ctx.stroke();
                ctx.globalAlpha = 1.0;
            }
        }
    }

    // Core label overlaid on top of the sparkline
    PlasmaComponents.Label {
        id: lbl
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.leftMargin: 4
        width: lane.showLabel ? implicitWidth + 4 : 0; visible: lane.showLabel
        verticalAlignment: Text.AlignVCenter
        z: 2
        text: {
            if (!cpuMode) return lane.label;
            var name = isHT ? ("  HT" + (htIndex >= 0 ? htIndex : ""))
                            : ("Core" + lane.coreNum);
            // Append current frequency when available
            if (cpuMode && lane.curFreq > 0) {
                var ghz = (lane.curFreq / 1000).toFixed(1);
                name += " " + ghz + "GHz";
            }
            return name;
        }
        font.pixelSize: Math.max(7, Math.min(13, lane.height * 0.55))
        elide: Text.ElideRight; opacity: lane.labelOpacity
    }

    Rectangle {
        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
        height: 1; color: "#ffffff"; opacity: 0.06
    }
}
