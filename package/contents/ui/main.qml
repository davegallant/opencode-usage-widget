import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---- config ----
    // The helper ships inside the package; resolve it relative to this file so
    // the widget works on any machine with no hardcoded home path.
    readonly property string scriptPath: Qt.resolvedUrl("../code/opencode-usage.py").toString().replace(/^file:\/\//, "")
    readonly property string cmd: "python3 '" + scriptPath + "'"
    // 5 minutes. This hits opencode's web frontend, not an API built for
    // polling, so it is deliberately slower than the Claude widget's 60s.
    readonly property int pollMs: 300000

    // ---- state ----
    property var rolling: null         // {util, resets_ms}
    property var weekly: null
    property var monthly: null
    property string errorMsg: ""
    property double nowMs: 0           // ticks every 15s for live countdowns
    property double lastFetchMs: 0
    property bool busy: false
    property int fetchSeq: 0           // makes each run a distinct DataSource source
    property int saveSeq: 0            // ditto, for credential writes

    Plasmoid.icon: "utilities-system-monitor"
    toolTipMainText: "opencode Usage"
    toolTipSubText: rolling
        ? ("Rolling " + Math.round(rolling.util) + "% · resets in " + remainStr(rolling.resets_ms)
           + (weekly ? ("\nWeekly " + Math.round(weekly.util) + "%") : "")
           + (monthly ? ("\nMonthly " + Math.round(monthly.util) + "%") : "")
           + "\nMiddle-click to refresh")
        : (errorMsg !== "" ? statusText() : "No data")

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Refresh now"
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        }
    ]

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.busy = false
            if (data["exit code"] !== 0) { root.errorMsg = "exec"; return }
            try {
                var p = JSON.parse(data["stdout"])
                if (p.error) {
                    root.errorMsg = p.error
                    // Only blank the data when the credential itself is gone.
                    // Transient failures (network blip, a payload shape we
                    // couldn't read this once) keep the last-known values so
                    // the widget degrades instead of flickering empty.
                    if (p.error === "no-curl" || p.error === "bad-curl"
                            || p.error === "http-401" || p.error === "http-403") {
                        root.rolling = root.weekly = root.monthly = null
                    }
                    return
                }
                root.rolling = p.rolling
                root.weekly = p.weekly
                root.monthly = p.monthly
                root.lastFetchMs = p.fetched_ms ? p.fetched_ms : new Date().getTime()
                root.errorMsg = ""
            } catch (e) {
                root.errorMsg = "parse"
            }
        }
    }

    // ---------- credential write ----------
    // The helper reads ~/.config/opencode-usage/curl.txt, so the config page's
    // value is written through to that file rather than passed to the helper
    // some other way -- one code path, and hand-editing the file still works
    // for anyone who prefers it.
    P5Support.DataSource {
        id: writer
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            if (data["exit code"] !== 0) {
                root.errorMsg = "save"
                return
            }
            root.refresh()
        }
    }

    // A DevTools curl is full of single quotes, so it cannot be interpolated
    // into a shell command directly. base64 output is alphanumeric plus +/=,
    // which is safe inside single quotes no matter what the input contained.
    function saveCurl() {
        var text = Plasmoid.configuration.curlCommand
        if (!text || text.trim() === "") return
        var dir = "\"$HOME/.config/opencode-usage\""
        var path = "\"$HOME/.config/opencode-usage/curl.txt\""
        root.saveSeq += 1
        writer.connectSource(
            "mkdir -p " + dir
            + " && printf %s '" + Qt.btoa(text) + "' | base64 -d > " + path
            + " && chmod 600 " + path
            + " # " + root.saveSeq)
    }

    // Fires on OK/Apply in the config dialog, and once at startup if a value
    // is already stored.
    Connections {
        target: Plasmoid.configuration
        function onCurlCommandChanged() { root.saveCurl() }
    }

    // Force a fetch now. The trailing shell comment gives every run a unique
    // source name, so a manual refresh re-executes instead of being swallowed
    // as a duplicate of the source already connected.
    function refresh() {
        root.busy = true
        root.fetchSeq += 1
        root.nowMs = new Date().getTime()
        exec.connectSource(root.cmd + " # " + root.fetchSeq)
    }

    Timer { interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.nowMs = new Date().getTime() }
    // Watchdog: the helper self-limits to a 10s HTTP timeout, so anything past
    // 20s means the run is gone — clear the spinner rather than wedge on it.
    Timer {
        interval: 20000; running: root.busy; repeat: false
        onTriggered: root.busy = false
    }

    // ---------- helpers ----------
    function remainStr(resetMs) {
        if (!resetMs) return "—"
        var ms = Math.max(0, resetMs - nowMs)
        var totalMin = Math.floor(ms / 60000)
        var d = Math.floor(totalMin / 1440)
        var h = Math.floor((totalMin % 1440) / 60)
        var m = totalMin % 60
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h" + (m < 10 ? "0" : "") + m + "m"
        return m + "m"
    }
    function resetAtStr(resetMs) {
        if (!resetMs) return ""
        return Qt.formatDateTime(new Date(resetMs), "ddd d MMM, h:mm ap")
    }
    function agoStr(ms) {
        if (!ms) return "never"
        var mins = Math.floor(Math.max(0, nowMs - ms) / 60000)
        if (mins < 1) return "just now"
        if (mins < 60) return mins + "m ago"
        return Math.floor(mins / 60) + "h ago"
    }
    // Severity tint by raw percentage. Pace-based colouring (as in the Claude
    // widget) needs the window length, and opencode's payload gives only a
    // relative reset — never the window size — so there is nothing honest to
    // project against.
    function utilColor(u) {
        if (u === undefined || u === null) return Kirigami.Theme.textColor
        if (u > 80) return Kirigami.Theme.negativeTextColor
        if (u > 50) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.positiveTextColor
    }
    function statusText() {
        if (errorMsg === "no-curl") return "Not configured"
        if (errorMsg === "save") return "Couldn't save credentials"
        if (errorMsg === "bad-curl") return "Bad curl file"
        if (errorMsg === "http-401" || errorMsg === "http-403") return "Session expired"
        if (errorMsg === "net" || errorMsg === "exec") return "Offline"
        if (errorMsg === "parse") return "Payload changed"
        return "Error"
    }
    // The long-form explanation, shown in the popup. Every case names the
    // action that fixes it.
    function errorDetail() {
        if (errorMsg === "no-curl")
            return "Not configured.\nRight-click → Configure, then paste the opencode console's\n_server request, copied as cURL."
        if (errorMsg === "save")
            return "Couldn't write ~/.config/opencode-usage/curl.txt."
        if (errorMsg === "bad-curl")
            return "Couldn't read that curl command.\nRe-copy it with \"Copy as cURL (bash)\" and paste it again\nunder Configure."
        if (errorMsg === "http-401" || errorMsg === "http-403")
            return "Session expired.\nRe-copy your curl from the opencode console."
        if (errorMsg === "parse")
            return "opencode changed its response format.\nThe widget's scraper needs updating."
        if (errorMsg === "net" || errorMsg === "exec")
            return "Couldn't reach opencode."
        if (errorMsg !== "")
            return "opencode returned an error (" + errorMsg + ")."
        return "Loading…"
    }

    // A usage bar tinted by severity. PlasmaComponents3.ProgressBar draws its
    // fill from a themed SVG and exposes no colour hook, so track and fill are
    // both plain rectangles here — replacing only one would leave the two
    // mismatched in height. The track alpha matches the compact ring's.
    component UsageBar: Item {
        id: bar
        property real value: 0
        property color fillColor
        implicitHeight: Math.max(4, Math.round(Kirigami.Units.gridUnit / 3))
        readonly property real fraction: Math.max(0, Math.min(100, bar.value)) / 100

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.18)
        }
        Rectangle {
            height: parent.height
            width: parent.width * bar.fraction
            radius: height / 2
            color: bar.fillColor
            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        }
    }

    // One labelled window: name, percentage, bar, reset line. `usage` rather
    // than `data` because `data` is Item's default property and cannot be
    // shadowed.
    component UsageRow: ColumnLayout {
        id: row
        property string label: ""
        property var usage: null
        Layout.fillWidth: true
        visible: row.usage !== null && row.usage !== undefined
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label { text: row.label; opacity: 0.8 }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                text: row.usage ? (Math.round(row.usage.util) + "%") : "—"
                font.bold: true
                color: row.usage ? root.utilColor(row.usage.util) : Kirigami.Theme.textColor
            }
        }
        UsageBar {
            Layout.fillWidth: true
            value: row.usage ? row.usage.util : 0
            fillColor: row.usage ? root.utilColor(row.usage.util)
                                 : Kirigami.Theme.disabledTextColor
        }
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: row.usage ? ("Resets in " + root.remainStr(row.usage.resets_ms)
                               + " · " + root.resetAtStr(row.usage.resets_ms)) : ""
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }

    // ---------- compact (in-panel): concentric rings, outside-in ----------
    // rolling / weekly / monthly, ordered by how soon each one bites. How many
    // are drawn depends on the panel's thickness -- see `dual` and `triple`.
    compactRepresentation: MouseArea {
        id: compact
        // Only one axis follows the other, and only the axis Plasma doesn't
        // already fix for us — binding both ways off Math.min(width, height)
        // is a binding loop.
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        Layout.minimumWidth: vertical ? Kirigami.Units.iconSizes.smallMedium : height
        Layout.minimumHeight: vertical ? width : Kirigami.Units.iconSizes.smallMedium
        Layout.preferredWidth: Layout.minimumWidth
        Layout.preferredHeight: Layout.minimumHeight
        readonly property real side: vertical ? width : height
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) root.refresh()
            else root.expanded = !root.expanded
        }

        readonly property real util: root.rolling ? root.rolling.util : 0
        // Not readonly: Behavior needs write access to animate through value
        // changes; Qt refuses to attach one to a readonly property.
        property real fraction: root.rolling ? Math.max(0, Math.min(100, util)) / 100 : 0
        readonly property color ringColor: root.rolling ? root.utilColor(root.rolling.util)
                                                        : Kirigami.Theme.disabledTextColor
        // Weekly mirrors rolling exactly: same clamp, same easing, same full
        // strength colour. A blown weekly quota is the worse of the two
        // problems and must not be drawn more quietly than a rolling one.
        property real weeklyFraction: root.weekly ? Math.max(0, Math.min(100, root.weekly.util)) / 100 : 0
        readonly property color weeklyColor: root.weekly ? root.utilColor(root.weekly.util)
                                                         : Kirigami.Theme.disabledTextColor
        // Monthly, innermost. Same treatment again -- three windows drawn on
        // equal terms, ordered outside-in by how soon they bite.
        property real monthlyFraction: root.monthly ? Math.max(0, Math.min(100, root.monthly.util)) / 100 : 0
        readonly property color monthlyColor: root.monthly ? root.utilColor(root.monthly.util)
                                                           : Kirigami.Theme.disabledTextColor
        Behavior on fraction { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        Behavior on weeklyFraction { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        Behavior on monthlyFraction { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

        Shape {
            id: ring
            anchors.centerIn: parent
            readonly property real d: Math.max(compact.side - Kirigami.Units.smallSpacing, 8)
            // Below this the inner ring would be present but unreadable —
            // strokes hit the 2px floor and the centre stops holding a
            // two-digit percentage above minimumPixelSize. Absent beats
            // illegible, so thin panels get the original single ring.
            readonly property bool dual: d >= 32
            // Monthly only appears once a third ring still leaves a usable
            // arc: at d = 40 the innermost radius is 8.3px with a 3.4px
            // stroke. Below that the panel keeps two rings and the centred
            // percentage instead, which carries more than three smudged arcs.
            readonly property bool triple: d >= 40
            readonly property real strokeW: dual ? Math.max(2, d * 0.085)
                                                 : Math.max(2, d * 0.12)
            readonly property real gap: Math.max(1, d * 0.04)
            readonly property real outerR: (d - strokeW) / 2
            // Clamped: at the d = 8 floor the subtraction goes negative.
            readonly property real innerR: Math.max(0, outerR - strokeW - gap)
            readonly property real thirdR: Math.max(0, innerR - strokeW - gap)
            // Whichever ring is actually innermost in the current mode.
            readonly property real innermostR: triple ? thirdR : (dual ? innerR : outerR)
            // Clear diameter inside that ring. The centre label needs this as
            // an explicit width — see the label's own comment.
            readonly property real clearD: Math.max(0, 2 * (innermostR - strokeW / 2))
            // ShapePath has no strokeOpacity; bake the alpha into the color.
            readonly property color trackColor: Qt.rgba(Kirigami.Theme.textColor.r,
                                                        Kirigami.Theme.textColor.g,
                                                        Kirigami.Theme.textColor.b, 0.18)
            width: d; height: d
            layer.enabled: true
            layer.samples: 4

            ShapePath {   // rolling track
                strokeColor: ring.trackColor
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.FlatCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.outerR; radiusY: radiusX
                    startAngle: 0; sweepAngle: 359.999
                }
            }
            ShapePath {   // rolling fill, clockwise from the top
                strokeColor: compact.ringColor
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.outerR; radiusY: radiusX
                    startAngle: -90; sweepAngle: 359.999 * compact.fraction
                }
            }
            ShapePath {   // weekly track
                // ShapePath is not an Item and has no `visible`; a transparent
                // stroke is how these two paths switch off below the threshold.
                strokeColor: ring.dual ? ring.trackColor : "transparent"
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.FlatCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.innerR; radiusY: radiusX
                    startAngle: 0; sweepAngle: 359.999
                }
            }
            ShapePath {   // weekly fill, clockwise from the top
                strokeColor: ring.dual ? compact.weeklyColor : "transparent"
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.innerR; radiusY: radiusX
                    startAngle: -90; sweepAngle: 359.999 * compact.weeklyFraction
                }
            }
            ShapePath {   // monthly track
                strokeColor: ring.triple ? ring.trackColor : "transparent"
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.FlatCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.thirdR; radiusY: radiusX
                    startAngle: 0; sweepAngle: 359.999
                }
            }
            ShapePath {   // monthly fill, clockwise from the top
                strokeColor: ring.triple ? compact.monthlyColor : "transparent"
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.d / 2; centerY: ring.d / 2
                    radiusX: ring.thirdR; radiusY: radiusX
                    startAngle: -90; sweepAngle: 359.999 * compact.monthlyFraction
                }
            }
        }

        PlasmaComponents3.Label {
            anchors.centerIn: parent
            // In triple mode the monthly ring owns the centre and the reading
            // moves to the tooltip -- except when there is nothing to draw.
            // With no data every ring is an empty track, so the centre is free
            // and this is the only thing distinguishing "not configured" from
            // "everything at zero". Dropping it unconditionally would lose
            // that signal exactly when it matters most.
            visible: !ring.triple || !root.rolling
            // fontSizeMode is a no-op without a width to fit against: an
            // unanchored Text's width is its own content width. Measured:
            // "100%" bold at 11px is 30px wide and does NOT shrink without
            // this line; with it, it scales down to fit. Without a width the
            // percentage draws straight over the inner ring at 100%.
            width: ring.clearD
            text: root.rolling ? (Math.round(root.rolling.util) + "%")
                               : (root.errorMsg !== "" ? "!" : "…")
            color: compact.ringColor
            font.bold: true
            // 0.26 in dual mode is load-bearing, not cosmetic: at 0.32 the
            // label needs ~30px against a ~24px clear centre.
            font.pixelSize: Math.round(ring.d * (ring.dual ? 0.26 : 0.32))
            font.features: { "tnum": 1 }
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 6
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // ---------- full (popup) ----------
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 15

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            // ---- header: title + refresh ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading { level: 3; text: "opencode Usage" }
                Item { Layout.fillWidth: true }

                PlasmaComponents3.Label {
                    text: root.busy ? "Refreshing…" : ("Updated " + root.agoStr(root.lastFetchMs))
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                PlasmaComponents3.BusyIndicator {
                    running: root.busy
                    visible: root.busy
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    text: "Refresh now"
                    enabled: !root.busy
                    onClicked: root.refresh()
                    PlasmaComponents3.ToolTip.text: "Fetch usage now"
                    PlasmaComponents3.ToolTip.visible: hovered
                    PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }

            UsageRow { label: "Rolling"; usage: root.rolling }
            UsageRow { label: "Weekly";  usage: root.weekly }
            UsageRow { label: "Monthly"; usage: root.monthly }

            // ---- error / unconfigured state ----
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.rolling === null
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
                opacity: 0.7
                text: root.errorDetail()
            }

            // A fetch failed but stale figures are still on screen. Say so,
            // quietly, instead of letting them look current.
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.rolling !== null && root.errorMsg !== ""
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                opacity: 0.7
                color: Kirigami.Theme.neutralTextColor
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: root.statusText() + " — showing last known figures"
            }

            Item { Layout.fillHeight: true }
        }
    }
}
