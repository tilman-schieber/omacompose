import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ComposeModel.js" as ComposeModel

// Which-key style overlay for the compose key. Hyprland (hypr/omacompose.lua)
// reports every key typed after Multi_key through `omacompose update`; the
// overlay shows what each possible next key produces. It never takes keyboard
// focus or input, so the real compose keeps working underneath it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Wait this long after the compose key before showing anything, so typing a
  // sequence you already know doesn't flash the overlay.
  property int showDelay: 250
  // Give up on a sequence after this long without a key.
  property int idleTimeout: 6000
  property int maxCells: 60

  property var table: ({ labels: {}, entries: [], sources: [] })
  property int seqId: 0
  property var seq: []
  property var view: ({ state: "dead", groups: [] })
  property bool opened: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
  readonly property var customGroups: view.groups.filter(function(g) { return g.custom })
  readonly property var otherGroups: view.groups.filter(function(g) { return !g.custom })
  // At the root only your own sequences get cells; the locale table's
  // first keys are listed as chips so the card stays small.
  readonly property bool atRoot: seq.length === 0
  readonly property var cellGroups: (atRoot ? customGroups : view.groups).slice(0, maxCells)
  readonly property int hiddenCount: (atRoot ? customGroups.length : view.groups.length) - cellGroups.length

  readonly property int pad: Style.space(14)
  readonly property int cellWidth: Style.space(168)
  readonly property int cellHeight: Style.space(30)
  readonly property int columns: Math.max(1, Math.min(5, cellGroups.length))

  function update(id, rawSeq) {
    var n = parseInt(id, 10) || 0
    if (n < seqId) return
    if (n > seqId) reload()
    seqId = n

    if (rawSeq === "!") { finish(false); return }
    seq = rawSeq === "-" || rawSeq === "" ? [] : rawSeq.split(",")
    view = ComposeModel.step(table, seq)
    idleTimer.restart()

    if (view.state !== "pending") { finish(true); return }
    if (opened) return
    if (seq.length > 0 || showDelay <= 0) opened = true
    else showTimer.restart()
  }

  function finish(resetSubmap) {
    showTimer.stop()
    idleTimer.stop()
    opened = false
    if (resetSubmap)
      Quickshell.execDetached(["hyprctl", "eval", "omacompose.reset(" + seqId + ")"])
  }

  // Re-read the compose files on every new sequence, so edits to ~/.XCompose
  // (or anything it includes) show up without restarting anything.
  function reload() {
    if (!loader.running) loader.running = true
  }

  Component.onCompleted: reload()

  Process {
    id: loader
    command: ["python3", "-I", root.pluginDir + "compose-table.py"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.table = JSON.parse(text)
          if (root.seqId > 0 && (root.opened || showTimer.running)) root.view = ComposeModel.step(root.table, root.seq)
        } catch (e) {
          console.warn("omacompose: bad compose table", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omacompose", text.trim())
    }
  }

  Timer {
    id: showTimer
    interval: root.showDelay
    onTriggered: if (root.view.state === "pending") root.opened = true
  }

  Timer {
    id: idleTimer
    interval: root.idleTimeout
    onTriggered: root.finish(true)
  }

  IpcHandler {
    target: "omacompose"
    function update(id: string, seq: string): string {
      root.update(id, seq)
      return "ok"
    }
    function hide(): string { root.finish(true); return "ok" }
    function reload(): string { root.reload(); return "ok" }
    function sources(): string { return (root.table.sources || []).join("\n") }
  }

  component Keycap: Rectangle {
    property alias text: capText.text
    property bool accent: false
    width: Math.max(height, capText.implicitWidth + Style.spacing.lg * 2)
    height: Style.space(22)
    radius: Math.max(2, Style.cornerRadius / 2)
    color: accent ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.popups.text, 0.06)
    border.width: Math.max(1, Style.space(1))
    border.color: accent ? Color.accent : Util.alpha(Color.popups.text, 0.3)
    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: Style.font.body
      color: Color.popups.text
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: {
      var monitor = Hyprland.focusedMonitor
      var name = monitor ? String(monitor.name || "") : ""
      for (var i = 0; i < Quickshell.screens.length; i++)
        if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
      return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omacompose"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: card
      width: Math.min(panel.width - Style.gapsOut * 4,
                      card.borderLeft + root.pad * 2 + Math.max(content.implicitWidth, Style.space(220)) + card.borderRight)
      height: card.borderTop + root.pad * 2 + content.implicitHeight + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(64)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Column {
        id: content
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        width: card.width - card.borderLeft - card.borderRight - root.pad * 2
        spacing: Style.spacing.xl

        // Typed so far: compose ' …
        Row {
          spacing: Style.spacing.md
          Keycap { text: "compose"; accent: true }
          Repeater {
            model: root.seq
            Keycap { required property string modelData; text: ComposeModel.label(root.table, modelData) }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            leftPadding: Style.spacing.md
            textFormat: Text.PlainText
            visible: !root.atRoot
            text: root.view.groups.length + " options"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Util.alpha(Color.popups.text, 0.6)
          }
        }

        Grid {
          id: grid
          visible: root.cellGroups.length > 0
          columns: root.columns
          columnSpacing: Style.spacing.xl
          rowSpacing: Style.spacing.sm

          Repeater {
            model: root.cellGroups
            Item {
              id: cell
              required property var modelData
              width: root.cellWidth
              height: root.cellHeight
              Keycap {
                id: cap
                anchors.verticalCenter: parent.verticalCenter
                text: cell.modelData.label
                accent: cell.modelData.custom
              }
              Text {
                id: result
                anchors.left: cap.right
                anchors.leftMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, cell.width - cap.width - Style.spacing.lg)
                textFormat: Text.PlainText
                text: cell.modelData.entry ? cell.modelData.entry.result : cell.modelData.results.join(" ") + " …"
                font.family: Style.font.family
                font.pixelSize: cell.modelData.entry ? Style.font.heading : Style.font.body
                color: cell.modelData.entry ? Color.popups.text : Util.alpha(Color.popups.text, 0.7)
                elide: Text.ElideRight
                maximumLineCount: 1
              }
              Text {
                anchors.left: result.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // Locale comments are just Unicode names; your own are worth showing.
                visible: !!cell.modelData.entry && cell.modelData.entry.custom && cell.modelData.entry.comment !== "" && width > Style.space(20)
                textFormat: Text.PlainText
                text: cell.modelData.entry ? cell.modelData.entry.comment.toLowerCase() : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Util.alpha(Color.popups.text, 0.5)
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }
          }
        }

        Text {
          visible: root.hiddenCount > 0
          textFormat: Text.PlainText
          text: "+ " + root.hiddenCount + " more"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.6)
        }

        // Root only: first keys of the locale's own sequences.
        Column {
          visible: root.atRoot && root.otherGroups.length > 0
          width: parent.width
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: "system sequences start with"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Util.alpha(Color.popups.text, 0.6)
          }
          Flow {
            width: Math.max(grid.width, Style.space(560))
            spacing: Style.spacing.sm
            Repeater {
              model: root.atRoot ? root.otherGroups : []
              Keycap { required property var modelData; text: modelData.label }
            }
          }
        }
      }
    }
  }
}
