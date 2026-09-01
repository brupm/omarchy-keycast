import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "KeycastModel.js" as M

// Keycast — shows the name of each key as it is pressed.
//
// Event source: `keyd monitor` (keyd is always running on this box and already
// normalizes names to leftcontrol / rightalt / rightmeta / ...). Needs read
// access to /dev/input/event*, i.e. membership in the `input` group. Until that
// is granted the process just produces nothing and the overlay stays hidden.
Item {
  id: root

  // ------------------------------------------------------------------ config
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/keycast.json"
  property string mode: "stream" // stream | chords | caption
  property bool _writingConfig: false

  // ------------------------------------------------------------------ timings
  readonly property int streamTtl: 1000
  readonly property int chordTtl: 1300
  readonly property int infoTtl: 1200
  readonly property int fadeMs: 150
  readonly property int captionIdleMs: 3000
  readonly property int captionMax: 14

  // ------------------------------------------------------------------ pill list
  // Each pill: { seq, text, accent (bool), born (epoch ms), ttl (ms) }.
  property var pills: []
  property int _seq: 0
  property double nowMs: 0

  // ------------------------------------------------------------- chord tracking
  property var heldMods: ({})       // keyd name -> true, currently held
  property var chordMods: []        // pretty names in press order, since held-count last hit 0
  property bool chordConsumed: false // a non-modifier key fired against the current mods

  // --------------------------------------------------------- caption tracking
  property var captionBuf: []
  property string captionText: ""

  readonly property bool hasContent:
    pills.length > 0 || (mode === "caption" && captionText.length > 0)

  // ====================================================================== IPC
  IpcHandler {
    target: "keycast"
    function cycleMode(): string { root.setMode(M.nextMode(root.mode)); return root.mode }
    function setMode(m: string): string { root.setMode(m); return root.mode }
    function getMode(): string { return root.mode }
    function ping(): string { return "ok" }
  }

  // =================================================================== config
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyConfig(configFile.text())
    onFileChanged: configFile.reload()
    onLoadFailed: root.ensureDefaultConfig()
  }

  Timer {
    id: writeGuardTimer
    interval: 300
    onTriggered: root._writingConfig = false
  }

  function applyConfig(raw) {
    if (root._writingConfig)
      return
    var m = "stream"
    try {
      var o = JSON.parse(raw || "{}")
      if (o && typeof o.mode === "string")
        m = o.mode
    } catch (e) {}
    m = M.normalizeMode(m)
    if (m !== root.mode) {
      root.mode = m
      root.resetTransientState()
    }
  }

  function ensureDefaultConfig() {
    root._writingConfig = true
    configFile.setText(JSON.stringify({ mode: "stream" }, null, 2) + "\n")
    writeGuardTimer.restart()
  }

  function writeConfig(m) {
    root._writingConfig = true
    configFile.setText(JSON.stringify({ mode: m }, null, 2) + "\n")
    writeGuardTimer.restart()
  }

  function setMode(m) {
    var nm = M.normalizeMode(m)
    root.mode = nm
    root.resetTransientState()
    root.writeConfig(nm)
    root.addPill("KEYCAST: " + nm.toUpperCase(), true, root.infoTtl)
  }

  function resetTransientState() {
    root.heldMods = ({})
    root.chordMods = []
    root.chordConsumed = false
    root.captionBuf = []
    root.captionText = ""
    captionIdleTimer.stop()
  }

  // ============================================================ event handling
  function handleLine(line) {
    var ev = M.parseLine(line)
    if (!ev || ev.state === "repeat")
      return
    handleEvent(ev.key, ev.state)
  }

  function handleEvent(key, state) {
    var mod = M.isModifier(key)

    if (state === "down") {
      if (mod) {
        if (!(key in root.heldMods)) {
          var hm = root.heldMods
          hm[key] = true
          root.heldMods = hm
          var cm = root.chordMods.slice()
          cm.push(M.pretty(key))
          root.chordMods = cm
        }
        if (root.mode === "stream")
          root.addPill(M.pretty(key), true, root.streamTtl)
        else if (root.mode === "caption")
          root.appendCaption(M.pretty(key))
        // chords: wait for a non-modifier key (combo) or release (bare tap)
      } else {
        if (root.mode === "stream") {
          root.addPill(M.pretty(key), false, root.streamTtl)
        } else if (root.mode === "caption") {
          root.appendCaption(M.pretty(key))
        } else { // chords
          var label = root.chordMods.length
            ? root.chordMods.concat([M.pretty(key)]).join("+")
            : M.pretty(key)
          root.addPill(label, false, root.chordTtl)
          root.chordConsumed = true
        }
      }
    } else if (state === "up") {
      if (mod && (key in root.heldMods)) {
        var hm2 = root.heldMods
        delete hm2[key]
        root.heldMods = hm2
        if (Object.keys(root.heldMods).length === 0) {
          if (root.mode === "chords" && !root.chordConsumed && root.chordMods.length > 0)
            root.addPill(root.chordMods.join("+"), true, root.chordTtl)
          root.chordMods = []
          root.chordConsumed = false
        }
      }
    }
  }

  function appendCaption(name) {
    var buf = root.captionBuf.slice()
    buf.push(name)
    while (buf.length > root.captionMax)
      buf.shift()
    root.captionBuf = buf
    root.captionText = buf.join("  ")
    captionIdleTimer.restart()
  }

  Timer {
    id: captionIdleTimer
    interval: root.captionIdleMs
    onTriggered: { root.captionBuf = []; root.captionText = "" }
  }

  // ================================================================ pill sweep
  function addPill(text, accent, ttl) {
    var arr = root.pills.slice()
    arr.push({ seq: ++root._seq, text: text, accent: !!accent, born: Date.now(), ttl: ttl })
    root.pills = arr
    root.nowMs = Date.now()
    sweepTimer.running = true
  }

  function sweep() {
    var t = Date.now()
    root.nowMs = t
    var arr = root.pills
    var kept = []
    for (var i = 0; i < arr.length; i++) {
      if (t - arr[i].born < arr[i].ttl + root.fadeMs)
        kept.push(arr[i])
    }
    if (kept.length !== arr.length)
      root.pills = kept
    if (kept.length === 0)
      sweepTimer.running = false
  }

  Timer {
    id: sweepTimer
    interval: 50
    repeat: true
    running: false
    onTriggered: root.sweep()
  }

  // ============================================================ keyd monitor
  Process {
    id: monitor
    command: ["keyd", "monitor"]
    running: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    // keyd prints "failed to open /dev/input/eventN" here when we lack the
    // `input` group. Swallow it — the retry warning below says what to do.
    stderr: SplitParser { onRead: function(line) {} }
    onExited: {
      console.warn("keycast: `keyd monitor` exited; retrying in 2s. "
        + "If keys never appear, add yourself to the input group: "
        + "sudo gpasswd -a $USER input, then log out and back in.")
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    onTriggered: monitor.running = true
  }

  // ================================================================== overlay
  component Pill: Rectangle {
    property string label: ""
    property bool accent: false
    implicitWidth: pillText.implicitWidth + Style.space(14) * 2
    implicitHeight: pillText.implicitHeight + Style.space(9) * 2
    radius: Math.max(Style.space(6), Style.cornerRadius)
    color: Util.alpha(Color.background, 0.97)
    border.width: 1
    border.color: Color.popups.border

    Text {
      id: pillText
      anchors.centerIn: parent
      text: parent.label
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: Style.font.title
      color: parent.accent ? Color.accent : Color.popups.text
    }
  }

  PanelWindow {
    id: panel
    visible: root.hasContent
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-keycast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Visual-only surface: empty input region so it never blocks the desktop.
    mask: Region {}

    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      spacing: Style.space(8)

      Row {
        id: pillRow
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.pills.length > 0
        spacing: Style.space(8)

        Repeater {
          model: root.pills
          delegate: Pill {
            required property var modelData
            label: modelData.text
            accent: modelData.accent
            opacity: {
              var age = root.nowMs - modelData.born
              if (age < modelData.ttl)
                return 1
              var f = 1 - (age - modelData.ttl) / root.fadeMs
              return f < 0 ? 0 : f
            }
            Behavior on opacity { NumberAnimation { duration: 90 } }
          }
        }
      }

      Pill {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.mode === "caption" && root.captionText.length > 0
        label: root.captionText
        accent: false
      }
    }
  }

  Component.onCompleted: Qt.callLater(function() { configFile.reload() })
}
