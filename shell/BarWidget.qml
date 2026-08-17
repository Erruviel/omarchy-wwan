import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mobile broadband (WWAN) bar widget. All state comes from `omarchy-wwan json`,
// the same status feed the old waybar module consumed: a cellular-bars glyph
// whose fill tracks signal strength, dimmed whenever the modem is powered but
// not carrying traffic. Hidden entirely on machines with no WWAN hardware.
BarWidget {
  id: root
  moduleName: "erruviel.wwan"

  // "absent" hides the widget; every other state shows the glyph the CLI sent.
  property string wwanState: "absent"
  property string icon: ""
  property string tip: ""

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  visible: icon !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "erruviel.wwan"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  Process {
    id: statusProc
    command: ["omarchy-wwan", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var st = JSON.parse(raw)
          root.wwanState = String(st["class"] || "absent")
          root.icon = String(st.text || "")
          root.tip = String(st.tooltip || "")
        } catch (e) {
          // A garbled line (CLI missing mid-uninstall) keeps the last state.
        }
      }
    }
  }

  // Connect/disconnect run detached; refresh when they exit so the icon
  // reacts as soon as the modem does, not at the next poll tick.
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    // The modem being up but idle (searching, registered, rfkill'd off) reads
    // as a dimmed glyph, exactly like the old waybar CSS did.
    opacity: root.wwanState === "connected" ? 1 : 0.5
    slotSize: Style.bar.statusSlot
    tooltipText: root.tip
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        actionProc.command = ["omarchy-wwan", "toggle"]
        actionProc.running = true
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.bar.run("omarchy-menu summon setup.mobile")
      }
    }
  }
}
