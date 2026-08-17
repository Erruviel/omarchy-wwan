import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mobile broadband (WWAN) bar widget with an anchored popup panel, following
// the same pattern as the first-party network/power/bluetooth widgets. All
// state comes from `omarchy-wwan panel` — one process spawn per refresh.
Panel {
  id: root
  moduleName: "erruviel.wwan"
  ipcTarget: "erruviel.wwan"

  property var info: ({})
  readonly property string wwanState: info.state || "absent"
  readonly property bool hwPresent: info.hw === "yes"
  readonly property bool installed: info.installed === "yes"
  readonly property bool connected: wwanState === "connected"
  readonly property bool busy: actionProc.running
  // Defaults to the empty cellular outline until the first read lands.
  readonly property string icon: info.icon || "󰢿"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)

  // The switch throws instantly on click; while the toggle is in flight it
  // shows where we are going, not where we still are.
  property bool desired: false
  readonly property bool switchChecked: busy ? desired : connected

  // Throughput and latency, mirroring the first-party network panel: rates
  // are deltas between successive --verbose samples, and ping keeps a rolling
  // window in which a timed-out probe counts as a lost packet.
  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property string prevIface: ""
  property real downloadRate: 0
  property real uploadRate: 0
  property var pingSamples: []
  property real pingLatency: -1
  property int packetLoss: 0
  readonly property int pingHistoryWindow: 24
  readonly property int pingAverageWindow: 5
  readonly property bool hasPingSamples: pingSamples.length > 0
  readonly property bool hasTransferStats: info.rx_bytes !== undefined
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : "#cc6666"

  // Data-plan meter, fed by the CLI's persistent usage accounting.
  readonly property real usedBytes: parseFloat(info.used_bytes || "0")
  readonly property real limitBytes: parseFloat(info.limit_bytes || "0")
  readonly property bool limitAck: info.limit_ack === "1"
  readonly property real usedFraction: limitBytes > 0 ? Math.min(1, usedBytes / limitBytes) : 0
  readonly property string nextResetLabel: {
    if (!info.next_reset) return ""
    var d = new Date(info.next_reset + "T00:00:00")
    if (isNaN(d.getTime())) return ""
    return "Resets " + Qt.formatDate(d, "MMM d")
  }

  readonly property string statusText: {
    switch (wwanState) {
    case "connected": return (info.operator || "Connected") + (info.tech ? " · " + info.tech : "")
    case "registered": return (info.operator || "Registered") + " — not connected"
    case "searching": return "Searching for network"
    case "nosim": return info.active_slot === "2"
      ? "eSIM is empty — no profile"
      : "SIM slot " + (info.active_slot || "?") + " is empty"
    case "locked": return "SIM locked — PIN required"
    case "disabled": return "Mobile data off"
    default: return "Modem starting…"
    }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshDetails() {
    if (!detailsProc.running) detailsProc.running = true
  }

  function updateInfo(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq > 0) next[lines[i].slice(0, eq)] = lines[i].slice(eq + 1)
    }
    // Keep the last known state across a transient empty read, so the widget
    // never blinks out while the CLI is briefly unavailable.
    if (Object.keys(next).length === 0) return
    updateStats(next)
    info = next
  }

  function updateStats(next) {
    var iface = next.iface || ""
    var now = Date.now() / 1000

    if (next.rx_bytes === undefined || iface !== prevIface || prevSampleTime === 0) {
      // First sample after open, or the modem moved to another interface —
      // a delta against the old counters would manufacture a spike.
      downloadRate = 0
      uploadRate = 0
    } else {
      var dt = now - prevSampleTime
      if (dt > 0) {
        downloadRate = Math.max(0, (parseFloat(next.rx_bytes) - prevRxBytes) / dt)
        uploadRate = Math.max(0, (parseFloat(next.tx_bytes) - prevTxBytes) / dt)
      }
    }
    prevIface = iface
    prevRxBytes = parseFloat(next.rx_bytes || "0")
    prevTxBytes = parseFloat(next.tx_bytes || "0")
    prevSampleTime = next.rx_bytes === undefined ? 0 : now

    if (next.ping_ms === undefined) return
    var v = parseFloat(next.ping_ms)
    var samples = pingSamples.slice()
    samples.push(isFinite(v) && v >= 0 ? v : null)
    while (samples.length > pingHistoryWindow) samples.shift()
    pingSamples = samples

    var total = 0, count = 0
    for (var i = Math.max(0, samples.length - pingAverageWindow); i < samples.length; i++) {
      if (typeof samples[i] === "number") { total += samples[i]; count++ }
    }
    pingLatency = count > 0 ? total / count : -1

    var lost = 0
    for (var j = 0; j < samples.length; j++) if (samples[j] === null) lost++
    packetLoss = Math.round((lost / samples.length) * 100)
  }

  function resetStats() {
    prevSampleTime = 0
    prevIface = ""
    downloadRate = 0
    uploadRate = 0
    pingSamples = []
    pingLatency = -1
    packetLoss = 0
  }

  function formatBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
    return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
  }

  function formatRate(bytesPerSec) {
    return formatBytes(bytesPerSec) + "/s"
  }

  function formatPing(ms) {
    if (!hasPingSamples) return "--"
    var v = parseFloat(ms)
    if (!isFinite(v) || v < 0) return "Timeout"
    return v.toFixed(v > 0 && v < 10 ? 1 : 0) + " ms"
  }

  function formatLoss(percent) {
    if (!hasPingSamples) return "--"
    var v = parseInt(percent, 10)
    return (!v || v < 0 ? 0 : v) + "%"
  }

  function runAction(cmd) {
    if (actionProc.running) return
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleData() {
    if (busy) return
    desired = !connected
    runAction(["omarchy-wwan", "toggle"])
  }

  // Flows that open their own UI (menu pickers, floating terminals) — the
  // panel gets out of their way first.
  function runDetached(cmd) {
    root.close()
    if (root.bar) root.bar.run(cmd)
  }

  onOpenedChanged: if (!opened) resetStats()

  visible: hwPresent
  implicitWidth: hwPresent ? button.implicitWidth : 0
  implicitHeight: hwPresent ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: ["omarchy-wwan", "panel"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  // The verbose feed adds byte counters and an interface-bound ping; the ping
  // can burn its full 1s timeout, so only the open panel pays for it.
  Process {
    id: detailsProc
    command: ["omarchy-wwan", "panel", "--verbose"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: actionProc
    onExited: root.opened ? root.refreshDetails() : root.refresh()
  }

  // Background poll for the bar icon; the open panel has its own cadence.
  Timer {
    interval: Math.max(2, root.setting("interval", 10)) * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Same rhythm as the Wi-Fi panel's stats poll.
  Timer {
    interval: 1500
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDetails()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    // Powered but not carrying traffic reads as a dimmed glyph, exactly like
    // the disconnected Wi-Fi arc next door.
    opacity: root.connected ? 1 : 0.5
    slotSize: Style.bar.statusSlot
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleData()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.hwPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · title/status · on-off switch ----------
        PanelHero {
          width: parent.width
          title: "Mobile Data"
          meta: root.statusText
          foreground: root.barForeground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: root.icon
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              visible: root.installed
              checked: root.switchChecked
              busy: root.busy
              foreground: root.barForeground
              onToggled: root.toggleData()
            }
          }
        }

        // ---------- Connection stats ----------
        // Same grid as the Wi-Fi panel: label/value pairs in two columns,
        // ping rows turning urgent as soon as a probe is lost.
        Row {
          visible: root.connected
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Operator"; value: root.info.operator || "—" }
            InfoPair { label: "Signal"; value: (root.info.signal || "0") + "%" }
            InfoPair {
              label: "Ping"
              value: root.formatPing(root.pingLatency)
              valueColor: root.packetLoss > 0 ? root.urgent : root.barForeground
            }
            InfoPair { label: "Receiving"; value: root.hasTransferStats ? root.formatRate(root.downloadRate) : "--" }
            InfoPair { label: "Downloaded"; value: root.hasTransferStats ? root.formatBytes(parseFloat(root.info.rx_bytes || "0")) : "--" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Technology"; value: root.info.tech || "—" }
            InfoPair { label: "IP"; value: (root.info.ip || "—").split("/")[0] }
            InfoPair {
              label: "Packet Loss"
              value: root.formatLoss(root.packetLoss)
              valueColor: root.packetLoss > 0 ? root.urgent : root.barForeground
            }
            InfoPair { label: "Sending"; value: root.hasTransferStats ? root.formatRate(root.uploadRate) : "--" }
            InfoPair { label: "Uploaded"; value: root.hasTransferStats ? root.formatBytes(parseFloat(root.info.tx_bytes || "0")) : "--" }
          }
        }

        // ---------- Data plan ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(planHeader.implicitHeight, planButton.implicitHeight)

            PanelSectionHeader {
              id: planHeader
              text: "DATA PLAN"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Button {
              id: planButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.limitBytes > 0 ? "Change" : "Set limit"
              fontSize: Style.font.caption
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.runDetached("omarchy-wwan limit-input")
            }
          }

          // Usage bar, following the battery panel's progress bar. Turns
          // urgent at 90% so the cutoff never comes as a surprise.
          Item {
            visible: root.limitBytes > 0
            width: parent.width
            implicitHeight: Style.space(8)

            Rectangle {
              id: planTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)
            }

            Rectangle {
              anchors.left: planTrack.left
              anchors.verticalCenter: planTrack.verticalCenter
              height: planTrack.height
              radius: planTrack.radius
              width: Math.max(planTrack.height, planTrack.width * root.usedFraction)
              color: root.usedFraction >= 0.9 ? root.urgent : root.barForeground
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }

          Item {
            width: parent.width
            implicitHeight: planUsed.implicitHeight

            Text {
              id: planUsed
              anchors.left: parent.left
              text: root.limitBytes > 0
                ? root.formatBytes(root.usedBytes) + " of " + (root.info.limit || root.formatBytes(root.limitBytes)) + (root.limitAck ? "  ·  cutoff off" : "")
                : "Used: " + root.formatBytes(root.usedBytes)
              color: root.usedFraction >= 1 ? root.urgent : root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.right: parent.right
              text: root.nextResetLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // System half missing: say what to do instead of showing dead controls.
        Text {
          visible: !root.installed
          width: parent.width
          wrapMode: Text.WordWrap
          text: "System side not installed — run install.sh from the plugin directory to enable connections."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- SIM slot ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "SIM CARD"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            id: simRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: simRow.cellWidth
              iconText: "󰒧"
              text: "Physical"
              bordered: true
              active: root.info.slot === "1"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: if (root.info.slot !== "1") root.runAction(["omarchy-wwan", "sim", "1"])
            }

            Button {
              width: simRow.cellWidth
              iconText: "󱤓"
              text: "eSIM"
              bordered: true
              active: root.info.slot === "2"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: if (root.info.slot !== "2") root.runAction(["omarchy-wwan", "sim", "2"])
            }
          }
        }

        // ---------- Carrier ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CARRIER" + (root.info.apn ? "  ·  APN " + root.info.apn : "")
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            id: carrierRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: carrierRow.cellWidth
              iconText: "󰐷"
              text: "Detect"
              tooltipText: "Read the carrier off the SIM and apply its APN"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.runDetached("omarchy-launch-floating-terminal-with-presentation 'omarchy-wwan carrier auto && omarchy-wwan apply'")
            }

            Button {
              width: carrierRow.cellWidth
              iconText: "󰇧"
              text: "Country"
              tooltipText: "Pick country, carrier and APN from the database"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.runDetached("omarchy-wwan carrier choose")
            }

            Button {
              width: carrierRow.cellWidth
              iconText: "󰑪"
              text: "APN"
              tooltipText: "Type an APN by hand"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.runDetached("omarchy-wwan apn-input")
            }
          }
        }

        // ---------- Autoconnect ----------
        PanelSeparator {
          visible: root.installed
          foreground: root.barForeground
        }

        Toggle {
          visible: root.installed
          width: parent.width
          label: "Autoconnect"
          description: "Bring mobile data up at boot"
          checked: root.info.autoconnect === "yes"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: root.runAction(["omarchy-wwan", "autoconnect", root.info.autoconnect === "yes" ? "off" : "on"])
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.barForeground

    width: parent.width
    spacing: Style.space(8)

    Text {
      text: parent.label
      color: root.barForeground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
