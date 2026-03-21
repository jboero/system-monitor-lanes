import QtQuick
import org.kde.plasma.components as PlasmaComponents
import org.kde.ksysguard.sensors as Sensors

/*
 * TempLaneItem - CPU package temperature sparkline.
 *
 * Subscribes to cpu/all/averageTemperature.
 * Canvas draws each line segment colored from blue (<=20C) to red (>=80C).
 */

Item {
    id: lane

    property real weight: 1.5
    property real totalWeight: 1
    property real availableHeight: 400
    property int maxSamples: 60
    property bool showLabel: true
    property bool showValue: true
    property int socket: 0

    // For parent compatibility
    property bool gotData: true
    property real maxFreq: 0

    property var history: []
    property real curTemp: 0
    property real lastTemp: 0
    property string displayValue: ""

    height: Math.max(16, availableHeight * weight / Math.max(1, totalWeight))
    clip: true

    readonly property real coldTemp: 20
    readonly property real hotTemp: 80

    // Sensor just stashes the latest value; sampling is timer-driven.
    Sensors.Sensor {
        // Use per-socket temp if available, otherwise fall back to overall average
        sensorId: "cpu/all/averageTemperature"
        enabled: true
        onValueChanged: {
            var v = Number(value) || 0;
            lane.lastTemp = v;
            lane.curTemp = v;
            lane.displayValue = v.toFixed(1) + "\u00B0C";
        }
    }

    // 1-second sample timer — matches CpuLaneItem rate for synchronized scrolling
    Timer {
        id: sampleTimer
        interval: 1000; running: true; repeat: true
        onTriggered: {
            var v = lane.lastTemp;
            lane.curTemp = v;
            lane.displayValue = v.toFixed(1) + "\u00B0C";

            var h = lane.history.slice();
            h.push(v);
            if (h.length > lane.maxSamples) h.splice(0, h.length - lane.maxSamples);
            lane.history = h;
            spark.requestPaint();
        }
    }

    function tempToColor(temp) {
        // Blue (cold) -> Green (healthy mid) -> Red (hot)
        var t = Math.max(0, Math.min(1, (temp - coldTemp) / (hotTemp - coldTemp)));
        if (t <= 0.5) {
            // Blue to green: 0->0.5
            var s = t * 2;
            var r = Math.round(60 * s);
            var g = Math.round(130 + 110 * s);
            var b = Math.round(255 - 180 * s);
            return "rgb(" + r + "," + g + "," + b + ")";
        } else {
            // Green to red: 0.5->1
            var s2 = (t - 0.5) * 2;
            var r2 = Math.round(60 + 195 * s2);
            var g2 = Math.round(240 - 190 * s2);
            var b2 = Math.round(75 - 50 * s2);
            return "rgb(" + r2 + "," + g2 + "," + b2 + ")";
        }
    }

    function tempToFillColor(temp) {
        var t = Math.max(0, Math.min(1, (temp - coldTemp) / (hotTemp - coldTemp)));
        if (t <= 0.5) {
            var s = t * 2;
            return "rgb(" + Math.round(20 + 15*s) + "," + Math.round(35 + 30*s) + "," + Math.round(80 - 40*s) + ")";
        } else {
            var s2 = (t - 0.5) * 2;
            return "rgb(" + Math.round(35 + 80*s2) + "," + Math.round(65 - 40*s2) + "," + Math.round(40 - 20*s2) + ")";
        }
    }

    // Returns a QML color object (for use with Qt.rgba in gradient stops)
    function tempToFillQColor(temp) {
        var t = Math.max(0, Math.min(1, (temp - coldTemp) / (hotTemp - coldTemp)));
        if (t <= 0.5) {
            var s = t * 2;
            return Qt.rgba((20 + 15*s)/255, (35 + 30*s)/255, (80 - 40*s)/255, 1.0);
        } else {
            var s2 = (t - 0.5) * 2;
            return Qt.rgba((35 + 80*s2)/255, (65 - 40*s2)/255, (40 - 20*s2)/255, 1.0);
        }
    }

    // Value (outside sparkline, on the right)
    PlasmaComponents.Label {
        id: val
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.rightMargin: 4
        width: lane.showValue ? 55 : 0; visible: lane.showValue
        verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignRight
        text: lane.displayValue
        font.pixelSize: Math.max(8, Math.min(13, lane.height * 0.4))
        opacity: 0.85; z: 2
    }

    // Sparkline with per-segment color — full width behind label
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

            // Temp range for Y axis: 0 to 110C
            var tMin = 0, tMax = 110;
            var samples = lane.maxSamples;
            var dx = w / Math.max(1, samples - 1);
            var ox = (samples - hist.length) * dx;

            // Fill with top-to-bottom gradient based on most recent temp
            ctx.beginPath(); ctx.moveTo(ox, h);
            for (var i = 0; i < hist.length; i++) {
                var x = ox + i * dx;
                var y = h - ((hist[i] - tMin) / (tMax - tMin)) * (h - 1);
                ctx.lineTo(x, Math.max(0, Math.min(h, y)));
            }
            ctx.lineTo(ox + (hist.length - 1) * dx, h); ctx.closePath();
            var fc = lane.tempToFillQColor(lane.curTemp);
            var grad = ctx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, Qt.rgba(fc.r, fc.g, fc.b, 0.45));
            grad.addColorStop(1, Qt.rgba(fc.r, fc.g, fc.b, 0.0));
            ctx.fillStyle = grad;
            ctx.fill();

            // Draw line segments, each colored by its temperature value
            for (var j = 1; j < hist.length; j++) {
                var x1 = ox + (j-1) * dx;
                var y1 = h - ((hist[j-1] - tMin) / (tMax - tMin)) * (h - 1);
                var x2 = ox + j * dx;
                var y2 = h - ((hist[j] - tMin) / (tMax - tMin)) * (h - 1);

                ctx.beginPath();
                ctx.moveTo(x1, Math.max(0, Math.min(h, y1)));
                ctx.lineTo(x2, Math.max(0, Math.min(h, y2)));
                // Color based on average temp of this segment
                ctx.strokeStyle = tempToColor((hist[j-1] + hist[j]) / 2);
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }
    }

    // Label overlaid on top of sparkline
    PlasmaComponents.Label {
        id: lbl
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.leftMargin: 4
        width: lane.showLabel ? implicitWidth + 4 : 0; visible: lane.showLabel
        verticalAlignment: Text.AlignVCenter
        text: "CPU " + lane.socket + " Temp"
        font.pixelSize: Math.max(8, Math.min(13, lane.height * 0.4))
        font.bold: true; opacity: 0.85; z: 2
    }

    // Bottom separator
    Rectangle {
        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
        height: 1; color: "#ffffff"; opacity: 0.1
    }
}
