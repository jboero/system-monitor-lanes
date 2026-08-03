import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.sensors as Sensors

PlasmoidItem {
    id: root

    readonly property int historySeconds: Plasmoid.configuration.historySeconds || 60
    readonly property bool showLabels: Plasmoid.configuration.showLabels !== false
    readonly property bool showValues: Plasmoid.configuration.showValues !== false
    readonly property bool showFreqLine: Plasmoid.configuration.showFreqLine === true
    readonly property bool freqWeighted: Plasmoid.configuration.freqWeightedUsage !== false
    readonly property bool combineThreads: Plasmoid.configuration.combineThreads === true
    readonly property bool capUtilization: Plasmoid.configuration.capUtilization !== false
    readonly property string customTitle: Plasmoid.configuration.title || ""
    readonly property int maxSamples: Math.max(2, historySeconds)

    readonly property string displayTitle: customTitle !== ""
        ? customTitle : "CPU Load Monitor"

    property var laneDefinitions: []
    property int coreCount: 0
    property real globalMaxFreq: 0
    property real totalWeight: 1
    property bool xhrBlocked: false     // true if XHR can't read files at all
    property bool xhrFinalized: false  // true once readSysData's finalize() has run
    property bool noFreqData: false     // true if cpufreq not available (uniform cores)
    property var cpuInfo: ({})
    property var coreGroups: ([])
    property int socketCount: 1
    // Map of logical CPU index -> online (bool). Polled from /sys so lanes can
    // render an offline state when cores are taken offline at runtime.
    property var cpuOnline: ({})

    Sensors.Sensor {
        sensorId: "cpu/all/coreCount"
        enabled: true
        onValueChanged: {
            var v = Number(value) || 0;
            if (v > 0) root.coreCount = v;
        }
    }

    // Safety timer: if readSysData never finalizes (XHR callbacks silently dropped),
    // declare XHR blocked after 3 seconds and fall back.
    Timer {
        id: xhrSafetyTimer
        interval: 3000; running: false; repeat: false
        onTriggered: {
            if (!root.xhrFinalized) {
                console.log("[system-monitor-lanes] XHR safety timeout — file:// access appears blocked. Set QML_XHR_ALLOW_FILE_READ=1.");
                root.xhrBlocked = true;
                buildFallbackList();
            }
        }
    }

    // Poll CPU online status so lanes can show cores taken offline at runtime.
    Timer {
        id: onlineTimer
        interval: 2000; repeat: true
        running: !root.xhrBlocked && root.laneDefinitions.length > 0
        triggeredOnStart: true
        onTriggered: root.pollOnlineStatus()
    }

    // Read /sys/devices/system/cpu/cpuN/online for every CPU that appears in a
    // lane. cpu0 (and CPUs that can't be offlined) expose no 'online' file, so
    // an empty response is treated as online.
    function pollOnlineStatus() {
        if (root.xhrBlocked) return;
        var lanes = root.laneDefinitions;
        var idxs = [];
        var seen = {};
        for (var i = 0; i < lanes.length; i++) {
            var ld = lanes[i];
            if (ld.mode !== "cpu") continue;
            if (seen[ld.idx] === undefined) { seen[ld.idx] = true; idxs.push(ld.idx); }
            if (ld.htCpus) {
                for (var j = 0; j < ld.htCpus.length; j++) {
                    var hc = ld.htCpus[j];
                    if (seen[hc] === undefined) { seen[hc] = true; idxs.push(hc); }
                }
            }
        }
        if (idxs.length === 0) return;

        var pending = idxs.length;
        var result = {};

        function finishOnline() {
            var prev = root.cpuOnline;
            var cameOnline = false;
            for (var ci2 in result) {
                if (result[ci2] === true && prev[ci2] === false) { cameOnline = true; break; }
            }
            root.cpuOnline = result;
            // A core came back online: its topology reappears, so re-scan and
            // rebuild to turn the offline placeholder into a real grouped lane.
            if (cameOnline) root.readSysData();
        }

        for (var k = 0; k < idxs.length; k++) {
            (function(ci) {
                var xhr = new XMLHttpRequest();
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === XMLHttpRequest.DONE) {
                        var txt = (xhr.responseText || "").trim();
                        result[ci] = (txt === "") ? true : (txt.charAt(0) === "1");
                        pending--;
                        if (pending <= 0) finishOnline();
                    }
                };
                try {
                    xhr.open("GET", "file:///sys/devices/system/cpu/cpu" + ci + "/online");
                    xhr.send();
                } catch(e) {
                    result[ci] = true;
                    pending--;
                    if (pending <= 0) root.cpuOnline = result;
                }
            })(idxs[k]);
        }
    }

    Component.onCompleted: readSysData()

    // -- Read /sys: topology, package_id, and optionally cpuinfo_max_freq
    function readSysData() {
        var info = {};
        var maxGlobal = 0;
        // 4 reads per CPU: siblings, package_id, max_freq, online
        var pending = 128 * 4;
        var xhrWorked = false;
        var finalized = false;

        // Start the safety timer in case XHR callbacks never fire
        root.xhrFinalized = false;
        xhrSafetyTimer.restart();

        for (var i = 0; i < 128; i++) {
            (function(idx) {
                // 1. Thread siblings
                sysRead("file:///sys/devices/system/cpu/cpu" + idx + "/topology/thread_siblings_list",
                    function(text) {
                        if (text !== "") {
                            xhrWorked = true;
                            var siblings = parseCpuList(text);
                            siblings.sort(function(a,b){return a-b;});
                            if (!info[idx]) info[idx] = {};
                            info[idx].isThread = (idx !== siblings[0]);
                            info[idx].primaryCpu = siblings[0];
                            info[idx].siblings = siblings;
                        }
                    });

                // 2. Physical package (socket) ID
                sysRead("file:///sys/devices/system/cpu/cpu" + idx + "/topology/physical_package_id",
                    function(text) {
                        if (text !== "") {
                            if (!info[idx]) info[idx] = {};
                            info[idx].socket = parseInt(text) || 0;
                        }
                    });

                // 3. Max frequency (optional — may not exist on server CPUs)
                sysRead("file:///sys/devices/system/cpu/cpu" + idx + "/cpufreq/cpuinfo_max_freq",
                    function(text) {
                        if (text !== "") {
                            var freq = parseInt(text);
                            if (!isNaN(freq) && freq > 0) {
                                if (!info[idx]) info[idx] = {};
                                info[idx].maxFreqKhz = freq;
                                if (freq > maxGlobal) maxGlobal = freq;
                            }
                        }
                    });

                // 4. Online flag — present but offline CPUs read "0" here while
                //    their topology/ dir is gone, so this is how we spot them.
                sysRead("file:///sys/devices/system/cpu/cpu" + idx + "/online",
                    function(text) {
                        if (text !== "") {
                            if (!info[idx]) info[idx] = {};
                            info[idx].online = (text.charAt(0) === "1");
                        }
                    });
            })(i);
        }

        function sysRead(url, callback) {
            var xhr = new XMLHttpRequest();
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    pending--;
                    callback((xhr.responseText || "").trim());
                    if (pending <= 0) finalize();
                }
            };
            try {
                xhr.open("GET", url);
                xhr.send();
            } catch(e) {
                pending--;
                if (pending <= 0) finalize();
            }
        }

        function finalize() {
            if (finalized) return;
            finalized = true;
            root.xhrFinalized = true;
            xhrSafetyTimer.stop();

            // Check if XHR worked at all (topology data for cpu0 exists?)
            if (!info[0] || info[0].primaryCpu === undefined) {
                root.xhrBlocked = true;
                buildFallbackList();
                return;
            }

            root.cpuInfo = info;
            root.globalMaxFreq = maxGlobal;
            root.noFreqData = (maxGlobal <= 0);

            // Count sockets
            var sockets = {};
            for (var idx in info) {
                if (info[idx].socket !== undefined)
                    sockets[info[idx].socket] = true;
            }
            root.socketCount = Math.max(1, Object.keys(sockets).length);

            // Present-but-offline CPUs: online flag is false and topology is
            // gone (no primaryCpu). These become dimmed "offline" placeholders.
            var offlineCpus = [];
            for (var oi in info) {
                if (info[oi].primaryCpu === undefined && info[oi].online === false)
                    offlineCpus.push(parseInt(oi));
            }
            offlineCpus.sort(function(a, b){ return a - b; });

            buildGroupedCpuList(info, maxGlobal, offlineCpus);
        }
    }

    function buildGroupedCpuList(info, maxGlobal, offlineCpus) {
        offlineCpus = offlineCpus || [];
        var groupMap = {};
        var cpuIndices = [];

        for (var idx in info) cpuIndices.push(parseInt(idx));
        cpuIndices.sort(function(a,b){return a-b;});

        for (var k = 0; k < cpuIndices.length; k++) {
            var ci = cpuIndices[k];
            var entry = info[ci];
            if (!entry) continue;
            // Must have topology data (primaryCpu). Freq is optional.
            if (entry.primaryCpu === undefined) continue;

            var primary = entry.primaryCpu;
            if (!groupMap[primary]) {
                groupMap[primary] = {
                    primary: primary,
                    threads: [],
                    maxFreq: entry.maxFreqKhz || 0,
                    socket: entry.socket || 0
                };
            }
            if (ci !== primary) {
                groupMap[primary].threads.push(ci);
            }
            if (entry.maxFreqKhz && entry.maxFreqKhz > groupMap[primary].maxFreq)
                groupMap[primary].maxFreq = entry.maxFreqKhz;
            if (entry.socket !== undefined)
                groupMap[primary].socket = entry.socket;
        }

        var groups = [];
        for (var p in groupMap) groups.push(groupMap[p]);

        var order = { "P": 0, "E": 1, "LP": 2 };

        // Index-range classifier for offline placeholders. Offline CPUs have no
        // topology, so we guess their type from where their index falls: pick
        // the type whose online cores start at the highest index still <= it.
        // On Intel hybrid, P threads precede E precede LP by index.
        var typeMinIdx = {};
        for (var gg = 0; gg < groups.length; gg++) {
            var gt = coreTypeFromFreq(groups[gg].maxFreq, maxGlobal);
            if (typeMinIdx[gt] === undefined || groups[gg].primary < typeMinIdx[gt])
                typeMinIdx[gt] = groups[gg].primary;
        }
        function classifyOffline(oi) {
            var best = "P", bestMin = -1;
            for (var tk in typeMinIdx) {
                if (typeMinIdx[tk] <= oi && typeMinIdx[tk] > bestMin) {
                    bestMin = typeMinIdx[tk]; best = tk;
                }
            }
            return best;
        }

        // Unified, sorted list of renderable entries: real core groups plus
        // offline placeholders, ordered by socket, then type, then index.
        var entries = [];
        for (var gi = 0; gi < groups.length; gi++) {
            entries.push({ kind: "core", socket: groups[gi].socket,
                type: coreTypeFromFreq(groups[gi].maxFreq, maxGlobal),
                sortIdx: groups[gi].primary, grp: groups[gi] });
        }
        for (var oj = 0; oj < offlineCpus.length; oj++) {
            entries.push({ kind: "off", socket: 0,
                type: classifyOffline(offlineCpus[oj]),
                sortIdx: offlineCpus[oj], cpu: offlineCpus[oj] });
        }
        entries.sort(function(a, b) {
            if (a.socket !== b.socket) return a.socket - b.socket;
            if (order[a.type] !== order[b.type]) return order[a.type] - order[b.type];
            return a.sortIdx - b.sortIdx;
        });

        var lanes = [];
        var tw = 0;
        var currentSocket = -1;
        var currentType = "";
        // Sequential physical-core number for display labels. Raw CPU indices
        // (grp.primary) are sparse once HT siblings are folded in — e.g.
        // 0,1,3,6,8,10 — so we renumber cores 0,1,2,... per socket for the
        // label only. Sensors still key off the real idx, not this ordinal.
        var coreOrdinal = 0;

        for (var e = 0; e < entries.length; e++) {
            var ent = entries[e];
            var type = ent.type;

            // Socket header
            if (ent.socket !== currentSocket) {
                currentSocket = ent.socket;
                currentType = "";
                coreOrdinal = 0;  // restart core numbering for each socket
                // Per-socket temperature lane
                lanes.push({ mode: "temp", weight: 1.2, socket: currentSocket });
                tw += 1.2;
            }

            // Core type header (only if there are multiple types)
            if (type !== currentType && maxGlobal > 0) {
                var typeNames = { "P": "Performance Cores", "E": "Efficiency Cores", "LP": "Low-Power Cores" };
                lanes.push({ mode: "header", text: "Socket " + currentSocket + " \u2014 " + (typeNames[type] || "Cores") });
                currentType = type;
            } else if (type !== currentType) {
                // No freq data — just label by socket
                lanes.push({ mode: "header", text: "Socket " + currentSocket + " Cores" });
                currentType = type;
            }

            var pw = weightForType(type);

            if (ent.kind === "off") {
                // Offline placeholder: labeled by raw cpuN (its physical core
                // and siblings are unknown while offline). Renders dimmed once
                // the online poll marks it offline in cpuOnline.
                lanes.push({
                    mode: "cpu", idx: ent.cpu, coreType: type,
                    weight: pw, maxFreqKhz: 0,
                    coreNum: ent.cpu, isHT: false, htIndex: -1,
                    htCpus: [], offlinePlaceholder: true
                });
                tw += pw;
                continue;
            }

            var grp = ent.grp;
            var displayCore = coreOrdinal++;  // sequential label for this core

            if (root.combineThreads && grp.threads.length > 0) {
                // Single lane per physical core, HT siblings overlaid as extra
                // lines. Weight sums the stacked lanes' weight so the combined
                // lane occupies the same vertical space they used to.
                var combinedWeight = pw * (1 + grp.threads.length);
                lanes.push({
                    mode: "cpu", idx: grp.primary, coreType: type,
                    weight: combinedWeight, maxFreqKhz: grp.maxFreq,
                    coreNum: displayCore, isHT: false, htIndex: -1,
                    htCpus: grp.threads.slice()
                });
                tw += combinedWeight;
            } else {
                lanes.push({
                    mode: "cpu", idx: grp.primary, coreType: type,
                    weight: pw, maxFreqKhz: grp.maxFreq,
                    coreNum: displayCore, isHT: false, htIndex: -1,
                    htCpus: []
                });
                tw += pw;

                for (var t = 0; t < grp.threads.length; t++) {
                    lanes.push({
                        mode: "cpu", idx: grp.threads[t], coreType: "HT",
                        weight: pw, maxFreqKhz: grp.maxFreq,
                        coreNum: displayCore, isHT: true, htIndex: t,
                        htCpus: []
                    });
                    tw += pw;
                }
            }
        }

        root.totalWeight = Math.max(1, tw);
        root.laneDefinitions = lanes;
        root.coreGroups = groups;
    }

    // Fallback: when XHR is blocked, build sequential list using coreCount
    function buildFallbackList() {
        var n = coreCount > 0 ? coreCount : 128;
        var lanes = [];
        var tw = 0;
        lanes.push({ mode: "temp", weight: 1.2, socket: 0 });
        tw += 1.2;
        lanes.push({ mode: "header", text: "CPU Cores" });
        for (var c = 0; c < n; c++) {
            lanes.push({
                mode: "cpu", idx: c, coreType: "P", weight: 1.0,
                maxFreqKhz: 0, coreNum: c, isHT: false, htIndex: -1
            });
            tw += 1.0;
        }
        root.totalWeight = Math.max(1, tw);
        root.laneDefinitions = lanes;
    }
    // Rebuild fallback when coreCount arrives
    onCoreCountChanged: {
        if (xhrBlocked) buildFallbackList();
    }

    // Rebuild lanes when the combine-threads option is toggled at runtime
    onCombineThreadsChanged: {
        if (xhrBlocked) return;  // fallback list has no topology to combine
        if (Object.keys(root.cpuInfo).length > 0)
            buildGroupedCpuList(root.cpuInfo, root.globalMaxFreq);
    }

    function coreTypeFromFreq(freq, maxGlobal) {
        if (maxGlobal <= 0) return "P";  // No freq data = treat all as uniform/P
        var ratio = freq / maxGlobal;
        if (ratio >= 0.85) return "P";
        if (ratio >= 0.6) return "E";
        return "LP";
    }

    function weightForType(type) {
        if (type === "P") return 1.0;
        if (type === "E") return 0.7;
        if (type === "LP") return 0.4;
        return 1.0;
    }

    function parseCpuList(text) {
        var result = [];
        var parts = text.split(",");
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i].trim();
            if (p.indexOf("-") >= 0) {
                var r = p.split("-");
                for (var x = parseInt(r[0]); x <= parseInt(r[1]); x++) result.push(x);
            } else {
                var v = parseInt(p);
                if (!isNaN(v)) result.push(v);
            }
        }
        return result;
    }

    compactRepresentation: PlasmaComponents.Label {
        text: root.displayTitle
        horizontalAlignment: Text.AlignHCenter
        MouseArea { anchors.fill: parent; onClicked: root.expanded = !root.expanded }
    }

    // -- Per-socket lane grouping for multi-socket layout --------
    // Each element: { socketId: N, lanes: [...], totalWeight: W, headerCount: H }
    property var socketLaneGroups: {
        var allLanes = root.laneDefinitions;
        if (allLanes.length === 0) return [];

        // For single socket, return one group with all lanes
        if (root.socketCount <= 1) {
            var tw = 0; var hc = 0;
            for (var i = 0; i < allLanes.length; i++) {
                if (allLanes[i].mode === "header") hc++;
                else if (allLanes[i].weight) tw += allLanes[i].weight;
            }
            return [{ socketId: 0, lanes: allLanes, totalWeight: Math.max(1, tw), headerCount: hc }];
        }

        // Multi-socket: split lanes by socket boundary (temp lanes mark the start of each socket group)
        var groups = [];
        var current = null;
        for (var j = 0; j < allLanes.length; j++) {
            var lane = allLanes[j];
            if (lane.mode === "temp") {
                // Start a new socket group
                if (current) groups.push(current);
                current = { socketId: lane.socket, lanes: [], totalWeight: 0, headerCount: 0 };
            }
            if (current) {
                current.lanes.push(lane);
                if (lane.mode === "header") current.headerCount++;
                else if (lane.weight) current.totalWeight += lane.weight;
            }
        }
        if (current) groups.push(current);

        // Ensure totalWeight is at least 1
        for (var g = 0; g < groups.length; g++)
            groups[g].totalWeight = Math.max(1, groups[g].totalWeight);

        return groups;
    }

    fullRepresentation: Item {
        id: fullRep
        Layout.minimumWidth: 250; Layout.minimumHeight: 150
        Layout.preferredWidth: 400; Layout.preferredHeight: 550

        PlasmaComponents.Label {
            id: titleLabel
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            anchors.margins: 4; text: root.displayTitle; font.bold: true
        }

        // XHR blocked notice — prominent warning banner
        Rectangle {
            id: notice
            anchors.top: titleLabel.bottom; anchors.left: parent.left; anchors.right: parent.right
            anchors.margins: 4
            visible: root.xhrBlocked
            height: visible ? noticeText.implicitHeight + 8 : 0
            radius: 3
            color: "#44ffaa00"
            border.color: "#88ffaa00"; border.width: 1

            PlasmaComponents.Label {
                id: noticeText
                anchors.fill: parent; anchors.margins: 4
                text: "\u26A0 Set QML_XHR_ALLOW_FILE_READ=1 for accurate CPU topology detection (core types, sockets, hyperthreading)."
                font.pixelSize: 10; wrapMode: Text.WordWrap
                opacity: 0.9
            }
        }

        Rectangle {
            id: sep
            anchors.top: notice.visible ? notice.bottom : titleLabel.bottom
            anchors.left: parent.left; anchors.right: parent.right
            anchors.topMargin: 2; height: 1; color: "#ffffff"; opacity: 0.12
        }

        Item {
            id: laneArea
            anchors.top: sep.bottom; anchors.left: parent.left
            anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.topMargin: 2; clip: true

            Row {
                id: socketRow
                anchors.fill: parent
                spacing: root.socketCount > 1 ? 2 : 0

                Repeater {
                    model: root.socketLaneGroups

                    delegate: Item {
                        id: socketColumn
                        width: (laneArea.width - (root.socketLaneGroups.length - 1) * socketRow.spacing) / Math.max(1, root.socketLaneGroups.length)
                        height: laneArea.height

                        property var groupData: modelData
                        property real groupTotalWeight: modelData.totalWeight
                        property int groupHeaderCount: modelData.headerCount
                        property real groupHeaderSpace: groupHeaderCount * 18
                        property real groupAvailHeight: height - groupHeaderSpace

                        // Thin vertical separator on the left side (except for the first column)
                        Rectangle {
                            visible: index > 0
                            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                            anchors.leftMargin: -1
                            width: 1; color: "#ffffff"; opacity: 0.1
                        }

                        Column {
                            id: socketCol
                            width: socketColumn.width; spacing: 0

                            Repeater {
                                model: socketColumn.groupData.lanes
                                delegate: Loader {
                                    width: socketCol.width
                                    sourceComponent: {
                                        if (modelData.mode === "header") return headerComp;
                                        if (modelData.mode === "temp") return tempComp;
                                        return laneComp;
                                    }
                                    property var laneData: modelData
                                    property real socketTotalWeight: socketColumn.groupTotalWeight
                                    property real socketAvailHeight: socketColumn.groupAvailHeight
                                }
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: headerComp
            Item {
                width: parent ? parent.width : 100
                height: 18
                property bool gotData: true
                property real maxFreq: 0
                PlasmaComponents.Label {
                    anchors.fill: parent; anchors.leftMargin: 4
                    text: laneData ? laneData.text : ""
                    font.pixelSize: 10; font.bold: true
                    verticalAlignment: Text.AlignBottom; opacity: 0.5
                }
            }
        }

        Component {
            id: tempComp
            TempLaneItem {
                width: parent ? parent.width : 100
                weight: laneData ? (laneData.weight || 1.2) : 1.2
                socket: laneData ? (laneData.socket || 0) : 0
                totalWeight: socketTotalWeight
                availableHeight: socketAvailHeight
                maxSamples: root.maxSamples
                showLabel: root.showLabels
                showValue: root.showValues
            }
        }

        Component {
            id: laneComp
            CpuLaneItem {
                width: parent ? parent.width : 100
                cpuMode: laneData ? (laneData.mode === "cpu") : false
                cpuIndex: laneData ? (laneData.idx || 0) : 0
                sensorId: laneData ? (laneData.sid || "") : ""
                label: laneData ? (laneData.lbl || "") : ""
                unit: laneData ? (laneData.u || "%") : "%"
                maxValue: laneData ? (laneData.mx || 100) : 100
                coreType: laneData ? (laneData.coreType || "P") : "P"
                weight: laneData ? (laneData.weight || 1.0) : 1.0
                maxSamples: root.maxSamples
                showLabel: root.showLabels
                showValue: root.showValues
                showFreqLine: root.showFreqLine
                freqWeighted: root.freqWeighted
                capAt100: root.capUtilization
                cpuOnline: root.cpuOnline
                coreCount: root.coreCount
                totalWeight: socketTotalWeight
                availableHeight: socketAvailHeight
                sysReadFailed: root.xhrBlocked
                maxFreqKhz: laneData ? (laneData.maxFreqKhz || 0) : 0
                coreNum: laneData ? (laneData.coreNum || 0) : 0
                isHT: laneData ? (laneData.isHT || false) : false
                htIndex: laneData ? (laneData.htIndex !== undefined ? laneData.htIndex : -1) : -1
                htCpus: laneData ? (laneData.htCpus || []) : []
                offlinePlaceholder: laneData ? (laneData.offlinePlaceholder || false) : false
            }
        }
    }

    preferredRepresentation: fullRepresentation
}
