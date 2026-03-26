import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQControls

Item {
    id: page

    // Plasma config dialog may set this
    property string title: i18n("General")

    // -- Config properties (Plasma injects cfg_* ) --
    property alias cfg_historySeconds: historySpinBox.value
    property alias cfg_showLabels: showLabelsCheckBox.checked
    property alias cfg_showValues: showValuesCheckBox.checked
    property string cfg_pCoreColor
    property string cfg_pCoreFill
    property string cfg_threadColor
    property string cfg_threadFill
    property string cfg_hotColor
    property alias cfg_hotThreshold: hotThresholdSpinBox.value
    property alias cfg_proportionalHeights: propHeightsCheckBox.checked
    property alias cfg_freqWeightedUsage: freqWeightedCheckBox.checked
    property alias cfg_tempHeatmap: tempHeatmapCheckBox.checked
    property alias cfg_showFreqLine: showFreqLineCheckBox.checked
    property alias cfg_title: titleField.text

    // Default-value stubs (Plasma 6 sets these for reset)
    property var cfg_historySecondsDefault
    property var cfg_showLabelsDefault
    property var cfg_showValuesDefault
    property var cfg_pCoreColorDefault
    property var cfg_pCoreFillDefault
    property var cfg_threadColorDefault
    property var cfg_threadFillDefault
    property var cfg_hotColorDefault
    property var cfg_hotThresholdDefault
    property var cfg_proportionalHeightsDefault
    property var cfg_freqWeightedUsageDefault
    property var cfg_tempHeatmapDefault
    property var cfg_showFreqLineDefault
    property var cfg_titleDefault

    // -- XHR file access detection --
    property bool xhrOk: false
    property bool xhrChecked: false

    // -- Live frequency debug data --
    // Tracks per-core: { sysMaxKhz, curFreq, minObserved, maxObserved }
    property var freqCoreData: ({})

    function refreshFreqDebug() {
        var pending = 128 * 3;  // max_freq, cur_freq (scaling), cpuinfo_min_freq per CPU
        var data = {};

        function done() {
            pending--;
            if (pending > 0) return;

            // Build grouped summary by core type (using same thresholds as main.qml)
            var globalMax = 0;
            for (var idx in data) {
                if ((data[idx].sysMaxKhz || 0) > globalMax) globalMax = data[idx].sysMaxKhz;
            }

            // Merge with persistent observed min/max
            var prev = page.freqCoreData;
            for (var ci in data) {
                var cur = data[ci].curKhz || 0;
                if (!prev[ci]) prev[ci] = { minObs: cur > 0 ? cur : 999999999, maxObs: 0 };
                if (cur > 0 && cur < prev[ci].minObs) prev[ci].minObs = cur;
                if (cur > prev[ci].maxObs) prev[ci].maxObs = cur;
                data[ci].minObs = prev[ci].minObs;
                data[ci].maxObs = prev[ci].maxObs;
            }
            page.freqCoreData = prev;

            // Group cores by type
            var groups = { "P": [], "E": [], "LP": [] };
            for (var c in data) {
                var d = data[c];
                var type = "P";
                if (globalMax > 0) {
                    var ratio = (d.sysMaxKhz || 0) / globalMax;
                    if (ratio < 0.6) type = "LP";
                    else if (ratio < 0.85) type = "E";
                }
                groups[type].push(d);
            }

            freqDebugModel.clear();
            var typeOrder = ["P", "E", "LP"];
            var typeNames = { "P": "P-cores", "E": "E-cores", "LP": "LP-cores" };
            for (var t = 0; t < typeOrder.length; t++) {
                var ty = typeOrder[t];
                var cores = groups[ty];
                if (cores.length === 0) continue;

                // Aggregate ranges across cores in this group
                var sysMin = 999999999, sysMax = 0;
                var minMin = 999999999;
                var curMin = 999999999, curMax = 0;
                var obsMin = 999999999, obsMax = 0;
                for (var j = 0; j < cores.length; j++) {
                    var cc = cores[j];
                    if (cc.sysMaxKhz > sysMax) sysMax = cc.sysMaxKhz;
                    if (cc.sysMaxKhz > 0 && cc.sysMaxKhz < sysMin) sysMin = cc.sysMaxKhz;
                    if (cc.sysMinKhz > 0 && cc.sysMinKhz < minMin) minMin = cc.sysMinKhz;
                    if (cc.curKhz > 0 && cc.curKhz < curMin) curMin = cc.curKhz;
                    if (cc.curKhz > curMax) curMax = cc.curKhz;
                    if (cc.minObs > 0 && cc.minObs < obsMin) obsMin = cc.minObs;
                    if (cc.maxObs > obsMax) obsMax = cc.maxObs;
                }

                function mhz(khz) { return (khz / 1000).toFixed(0); }

                freqDebugModel.append({ line: typeNames[ty] + " (" + cores.length + " cores):" });
                freqDebugModel.append({ line: "  sysfs max:     " + mhz(sysMax) + " MHz" });
                if (minMin < 999999999)
                    freqDebugModel.append({ line: "  sysfs min:     " + mhz(minMin) + " MHz" });
                freqDebugModel.append({ line: "  current range: " + mhz(curMin) + " – " + mhz(curMax) + " MHz" });
                if (obsMin < 999999999)
                    freqDebugModel.append({ line: "  observed min:  " + mhz(obsMin) + " MHz" });
                freqDebugModel.append({ line: "  observed max:  " + mhz(obsMax) + " MHz" });
                if (obsMax > sysMax && sysMax > 0)
                    freqDebugModel.append({ line: "  ⚠ observed exceeds sysfs max by " + mhz(obsMax - sysMax) + " MHz" });
            }
        }

        for (var i = 0; i < 128; i++) {
            (function(idx) {
                readSysVal("file:///sys/devices/system/cpu/cpu" + idx + "/cpufreq/cpuinfo_max_freq",
                    function(val) { if (val > 0) { if (!data[idx]) data[idx] = {}; data[idx].sysMaxKhz = val; } done(); });
                readSysVal("file:///sys/devices/system/cpu/cpu" + idx + "/cpufreq/scaling_cur_freq",
                    function(val) { if (val > 0) { if (!data[idx]) data[idx] = {}; data[idx].curKhz = val; } done(); });
                readSysVal("file:///sys/devices/system/cpu/cpu" + idx + "/cpufreq/cpuinfo_min_freq",
                    function(val) { if (val > 0) { if (!data[idx]) data[idx] = {}; data[idx].sysMinKhz = val; } done(); });
            })(i);
        }
    }

    function readSysVal(url, callback) {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                var v = parseInt((xhr.responseText || "").trim());
                callback(isNaN(v) ? 0 : v);
            }
        };
        try { xhr.open("GET", url); xhr.send(); }
        catch(e) { callback(0); }
    }

    Component.onCompleted: {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                page.xhrOk = ((xhr.responseText || "").trim() !== "");
                page.xhrChecked = true;
            }
        };
        try {
            xhr.open("GET", "file:///sys/devices/system/cpu/cpu0/topology/thread_siblings_list");
            xhr.send();
        } catch(e) {
            page.xhrOk = false;
            page.xhrChecked = true;
        }
        xhrCheckTimer.start();
    }

    Timer {
        id: xhrCheckTimer
        interval: 2000; running: false; repeat: false
        onTriggered: {
            if (!page.xhrChecked) {
                page.xhrOk = false;
                page.xhrChecked = true;
            }
        }
    }

    Flickable {
        id: flickable
        anchors.fill: parent
        contentHeight: formLayout.implicitHeight
        contentWidth: width
        clip: true
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        QQC2.ScrollBar.vertical: QQC2.ScrollBar {
            policy: flickable.contentHeight > flickable.height
                ? QQC2.ScrollBar.AlwaysOn : QQC2.ScrollBar.AsNeeded
        }

    Kirigami.FormLayout {
        id: formLayout
        width: flickable.width

        // ── XHR Environment Note ────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: xhrNoteText.implicitHeight + 10
            radius: 3
            color: (page.xhrChecked && !page.xhrOk) ? "#30ffaa00" : "#2000aa44"
            border.color: (page.xhrChecked && !page.xhrOk) ? "#88ffaa00" : "#4400aa44"
            border.width: 1
            QQC2.Label {
                id: xhrNoteText
                anchors.fill: parent; anchors.margins: 5
                wrapMode: Text.WordWrap
                textFormat: Text.RichText
                font.pixelSize: 11
                text: {
                    if (!page.xhrChecked)
                        return "\u2026 Checking environment\u2026";
                    if (page.xhrOk)
                        return "\u2714 <b>QML_XHR_ALLOW_FILE_READ=1</b> is set \u2014 CPU topology detection active.";
                    return "\u26A0 <b>QML_XHR_ALLOW_FILE_READ=1</b> is not set. " +
                        "DBus does not expose CPU topology or max frequency. " +
                        "This variable enables reading <tt>/sys</tt> for accurate CPU metrics.<br/>" +
                        "Add to <tt>/etc/environment</tt> and restart Plasma.";
                }
            }
        }

        // ── General ─────────────────────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("General")
        }

        QQC2.TextField {
            id: titleField
            Kirigami.FormData.label: i18n("Title (blank=auto):")
            QQC2.ToolTip.text: i18n("Custom widget title. Leave empty to use the default \"CPU Load Monitor\".")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }

        QQC2.SpinBox {
            id: historySpinBox
            Kirigami.FormData.label: i18n("History (sec):")
            from: 10; to: 600; stepSize: 10
            QQC2.ToolTip.text: i18n("How many seconds of history the sparkline graphs display. Longer values show more history but use more memory.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }

        // ── Display ─────────────────────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Display")
        }

        QQC2.CheckBox {
            id: showLabelsCheckBox
            Kirigami.FormData.label: i18n("Show:")
            text: i18n("Labels")
            QQC2.ToolTip.text: i18n("Show core name and frequency labels overlaid on the left side of each lane.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        QQC2.CheckBox {
            id: showValuesCheckBox
            text: i18n("Values")
            QQC2.ToolTip.text: i18n("Show the current utilization percentage on the right side of each lane.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }

        // ── CPU Features ────────────────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("CPU Features")
        }

        QQC2.CheckBox {
            id: propHeightsCheckBox
            text: i18n("Proportional lane heights (P vs E)")
            QQC2.ToolTip.text: i18n("Give P-cores taller lanes than E-cores and LP-cores, reflecting their relative performance weight.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        QQC2.CheckBox {
            id: freqWeightedCheckBox
            text: i18n("Frequency-weighted usage")
            QQC2.ToolTip.text: i18n("Scale reported CPU usage by (current freq / max freq) so a core at 50% load but half clock speed shows ~25% effective throughput. Requires QML_XHR_ALLOW_FILE_READ=1.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        QQC2.CheckBox {
            id: tempHeatmapCheckBox
            text: i18n("Temperature heatmap")
            QQC2.ToolTip.text: i18n("Show a per-socket temperature sparkline lane with blue\u2192green\u2192red color gradient based on current temperature.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        QQC2.CheckBox {
            id: showFreqLineCheckBox
            text: i18n("Show frequency line")
            QQC2.ToolTip.text: i18n("Draw a subtle gray line in each CPU lane showing the current clock speed as a percentage of max frequency. Useful for visualizing turbo boost and throttling.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        QQC2.SpinBox {
            id: hotThresholdSpinBox
            Kirigami.FormData.label: i18n("Hot threshold (\u00B0C):")
            from: 50; to: 110; stepSize: 5
            QQC2.ToolTip.text: i18n("Temperature at which the heatmap color reaches full red. Adjust based on your CPU's thermal limits.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }

        // ── Colors ──────────────────────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Colors")
        }

        KQControls.ColorButton {
            id: pCoreColorBtn
            Kirigami.FormData.label: i18n("P-core line:")
            showAlphaChannel: false
            color: page.cfg_pCoreColor || "#4da6ff"
            onColorChanged: page.cfg_pCoreColor = color.toString()
            QQC2.ToolTip.text: i18n("Sparkline stroke color for Performance cores.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        KQControls.ColorButton {
            id: pCoreFillBtn
            Kirigami.FormData.label: i18n("P-core fill:")
            showAlphaChannel: true
            color: page.cfg_pCoreFill || "#264d73"
            onColorChanged: page.cfg_pCoreFill = color.toString()
            QQC2.ToolTip.text: i18n("Gradient fill color for the area under P-core sparklines.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        KQControls.ColorButton {
            id: threadColorBtn
            Kirigami.FormData.label: i18n("Thread line:")
            showAlphaChannel: false
            color: page.cfg_threadColor || "#5a8a5a"
            onColorChanged: page.cfg_threadColor = color.toString()
            QQC2.ToolTip.text: i18n("Sparkline stroke color for hyperthread sibling lanes.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        KQControls.ColorButton {
            id: threadFillBtn
            Kirigami.FormData.label: i18n("Thread fill:")
            showAlphaChannel: true
            color: page.cfg_threadFill || "#2d4a2d"
            onColorChanged: page.cfg_threadFill = color.toString()
            QQC2.ToolTip.text: i18n("Gradient fill color for the area under hyperthread sparklines.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }
        KQControls.ColorButton {
            id: hotColorBtn
            Kirigami.FormData.label: i18n("Hot color:")
            showAlphaChannel: false
            color: page.cfg_hotColor || "#ff4444"
            onColorChanged: page.cfg_hotColor = color.toString()
            QQC2.ToolTip.text: i18n("Color used when temperature reaches the hot threshold.")
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: 500
        }

        // ── About ───────────────────────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("About")
        }

        QQC2.Label {
            text: "System Monitor Lanes v1.2.5"
            font.bold: true
        }
        QQC2.Label {
            text: "Vibe coded with \u2764 by John Boero & Claude"
        }
        QQC2.Label {
            text: "<a href=\"https://www.github.com/jboero/system-monitor-lanes\">github.com/jboero/system-monitor-lanes</a>"
            textFormat: Text.RichText
            onLinkActivated: function(link) { Qt.openUrlExternally(link); }
            MouseArea {
                anchors.fill: parent
                cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                acceptedButtons: Qt.NoButton
            }
        }

        // ── Live Frequency Debug ──────────────────────────
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Live Core Frequency Ranges")
        }

        QQC2.Label {
            text: page.xhrChecked && !page.xhrOk
                ? "Requires QML_XHR_ALLOW_FILE_READ=1"
                : freqDebugModel.count === 0 ? "Scanning…" : ""
            visible: (page.xhrChecked && !page.xhrOk) || freqDebugModel.count === 0
            font.italic: true; opacity: 0.6
        }

        Repeater {
            model: ListModel { id: freqDebugModel }
            delegate: QQC2.Label {
                text: model.line
                font.pixelSize: 11
                font.family: "monospace"
                opacity: 0.8
            }
        }

        // Timer to poll live frequencies from /sys
        Timer {
            id: freqDebugTimer
            interval: 1500; running: page.xhrChecked && page.xhrOk; repeat: true
            triggeredOnStart: true
            onTriggered: page.refreshFreqDebug()
        }
    }
    } // end Flickable
}
