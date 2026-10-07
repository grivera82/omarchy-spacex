import QtQuick
import Quickshell
import Quickshell.Io

// Owns the single `spacex daemon` process, which polls Launch Library 2 within
// its hourly request budget, caches patches and photos, runs the mpv player and
// sends launch alerts. Bar widgets on every monitor share this state.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string cli: String(Qt.resolvedUrl("bin/spacex")).replace(/^file:\/\//, "")

  property var state: ({ status: "starting" })
  property string lastError: ""
  property int serial: 0
  // Set when a notification's "Open" is clicked; the panel opens on that launch.
  property string openRequest: ""
  property int openSerial: 0

  readonly property bool running: daemon.running
  readonly property var config: state.config || ({})
  readonly property var launches: state.launches || []
  readonly property var recent: state.recent || []
  readonly property var player: state.player || ({ playing: false })
  readonly property string imgDir: state.imgDir || ""

  function send(cmd, args) {
    if (!daemon.running) return false
    daemon.write(JSON.stringify(Object.assign({ cmd: cmd, id: ++serial }, args || {})) + "\n")
    return true
  }

  function setConfig(key, value) { var a = {}; a[key] = value; return send("config", a) }
  function openUrl(url) { return url ? send("open", { url: url }) : false }
  function watch(launchId, opts) { return send("watch", Object.assign({ launch: launchId || "" }, opts || {})) }
  function stop() { return send("stop") }
  function playerCommand(args) { return send("player", { args: args }) }

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type === "state") {
      root.state = msg.state || {}
    } else if (msg.type === "result" && !msg.ok && msg.error) {
      root.lastError = msg.error
      clearError.restart()
    } else if (msg.type === "open") {
      root.openRequest = msg.id || ""
      root.openSerial++
      // summon() routes to the bar on the focused monitor, not every screen's copy.
      if (root.shell && typeof root.shell.summon === "function") root.shell.summon("grivera.spacex")
    } else if (msg.type === "log" && msg.error) {
      console.warn("grivera.spacex:", msg.error)
    }
  }

  Process {
    id: daemon
    command: [root.cli, "daemon"]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onRunningChanged: {
      if (running) return
      root.state = Object.assign({}, root.state, { status: "stopped" })
      restart.restart()
    }
  }

  Timer {
    id: restart
    interval: 10000
    onTriggered: daemon.running = true
  }

  Timer {
    id: clearError
    interval: 8000
    onTriggered: root.lastError = ""
  }
}
