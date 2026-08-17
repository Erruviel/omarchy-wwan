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

  readonly property string statusText: {
    switch (wwanState) {
    case "connected": return (info.operator || "Connected") + (info.tech ? " · " + info.tech : "")
    case "registered": return (info.operator || "Registered") + " — not connected"
    case "searching": return "Searching for network"
    case "locked": return "SIM locked — PIN required"
    case "disabled": return "Mobile data off"
    default: return "Modem starting…"
    }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
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
    info = next
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

  onOpenedChanged: if (opened) refresh()

  visible: hwPresent
  implicitWidth: hwPresent ? button.implicitWidth : 0
  implicitHeight: hwPresent ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: ["omarchy-wwan", "panel"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer {
    interval: Math.max(2, root.setting("interval", 10)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Tighter cadence while the panel is open, so signal and IP track live.
  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.refresh() }

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
        Row {
          visible: root.connected
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Operator"; value: root.info.operator || "—" }
            InfoPair { label: "Signal"; value: (root.info.signal || "0") + "%" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Technology"; value: root.info.tech || "—" }
            InfoPair { label: "IP"; value: (root.info.ip || "—").split("/")[0] }
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
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
