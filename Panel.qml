import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// SpaceX launches panel. Polling, image caching, the player and alerts live in
// the daemon behind Service.qml; this widget renders its state and runs the
// countdown clocks.
Panel {
  id: root
  moduleName: "grivera.spacex"
  ipcTarget: "grivera.spacex"
  manageIpc: false

  // Panel commands plus status(), which voice assistants (Jarvis) and scripts
  // read: `omarchy-shell grivera.spacex status`.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return JSON.stringify(root.statusSummary()) }
  }

  function statusTime(ts) { return ts ? Qt.formatDateTime(new Date(ts * 1000), "ddd MMM d, h:mm AP") : "" }

  // The next launches with countdowns, then recent results.
  function statusSummary() {
    if (!svc || !launches.length) return { error: "SpaceX Launches is still loading" }
    var now = Date.now() / 1000
    function launch(l, done) {
      var o = { name: l.name, rocket: l.rocket, status: l.status ? l.status.name : "",
                when: timed(l) ? root.statusTime(l.net) + (l.precision === "rough" ? " (approximate)" : "") : l.netLabel,
                pad: l.pad ? l.pad.short + ", " + l.pad.place : "" }
      if (!done && timed(l)) o.countdown = tClock(l)
      if (l.mission) {
        if (l.mission.orbit) o.orbit = l.mission.orbit
        if (l.mission.customers && l.mission.customers.length) o.customer = l.mission.customers.join(", ")
        if (l.mission.description) o.about = l.mission.description.split(/\r?\n/)[0].slice(0, 220)
      }
      if (l.probability >= 0 && l.probability !== null && l.probability !== undefined) o.weatherGoPercent = l.probability
      var b = boosterSummary(l)
      if (b) o.booster = b
      var crew = crewOf(l).map(function(c) { return c.name })
      if (crew.length) o.crew = crew
      if (l.webcastLive) o.webcastLive = true
      if (l.phase === "flight") o.inFlight = true
      if (l.starlink) o.starlink = true
      return o
    }
    return {
      now: root.statusTime(now),
      upcoming: launches.slice(0, 6).map(function(l) { return launch(l, false) }),
      recent: recent.slice(0, 4).map(function(l) { return launch(l, true) }),
      launchesThisYear: recent.length && recent[0].yearCount ? recent[0].yearCount : null,
      successStreak: st.stats ? st.stats.streak : null,
      playerOpen: !!player.playing
    }
  }


  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor("grivera.spacex") : null
  readonly property var st: svc ? svc.state : ({})
  readonly property var config: svc ? svc.config : ({})
  readonly property var launches: svc ? svc.launches : []
  readonly property var recent: svc ? svc.recent : []
  readonly property var player: svc ? svc.player : ({ playing: false })

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color wash: Qt.rgba(fg.r, fg.g, fg.b, 0.04)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property color go: "#3fb950"
  readonly property color warn: "#d29922"
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property string rocket: String.fromCodePoint(0xF0463)
  readonly property string rocketLaunch: String.fromCodePoint(0xF14DE)
  readonly property string playGlyph: String.fromCodePoint(0xF040A)
  readonly property string stopGlyph: String.fromCodePoint(0xF04DB)
  readonly property string pipGlyph: String.fromCodePoint(0xF0E59)
  readonly property string fullGlyph: String.fromCodePoint(0xF0293)
  readonly property string pinGlyph: String.fromCodePoint(0xF034E)
  readonly property string linkGlyph: String.fromCodePoint(0xF03CC)
  readonly property string checkGlyph: String.fromCodePoint(0xF05E0)
  readonly property string crossGlyph: String.fromCodePoint(0xF0159)
  readonly property string shipGlyph: String.fromCodePoint(0xF0213)
  readonly property string earthGlyph: String.fromCodePoint(0xF01E7)
  readonly property string cloudGlyph: String.fromCodePoint(0xF0590)
  readonly property string satGlyph: String.fromCodePoint(0xF0909)
  readonly property string flagGlyph: String.fromCodePoint(0xF023C)
  readonly property string calGlyph: String.fromCodePoint(0xF00ED)

  property string tab: "launch"
  property string selectedId: ""
  property string scheduleFilter: "all"
  property bool showAllStreams: false
  property bool descExpanded: false
  property bool timelineAll: false

  property double nowMs: Date.now()
  readonly property double nowSec: nowMs / 1000
  Timer {
    interval: root.opened || root.barClock ? 1000 : 20000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---- derived launches ----

  readonly property var nextLaunch: {
    var now = nowSec
    for (var i = 0; i < launches.length; i++) {
      var l = launches[i]
      if (l.phase === "flight" || l.net > now - flightWindow(l)) return l
    }
    return launches.length ? launches[0] : null
  }

  readonly property var selected: {
    if (selectedId) {
      var all = launches.concat(recent)
      for (var i = 0; i < all.length; i++) if (all[i].id === selectedId) return all[i]
    }
    return nextLaunch
  }

  readonly property bool live: !!nextLaunch && (nextLaunch.webcastLive || nextLaunch.phase === "flight")
  readonly property bool barClock: {
    var l = nextLaunch
    if (!l || config.barCountdown === false || (root.bar && root.bar.vertical) || !timed(l)) return false
    var s = l.net - nowSec
    return live || (s < 3600 && s > -flightWindow(l))
  }
  readonly property bool soon: !!nextLaunch && timed(nextLaunch) && nextLaunch.net - nowSec < 86400 && nextLaunch.net - nowSec > -flightWindow(nextLaunch)

  property real pulse: 1
  SequentialAnimation on pulse {
    running: root.live || root.player.playing
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
  }

  implicitWidth: clockButton.visible ? clockButton.implicitWidth : button.implicitWidth
  implicitHeight: clockButton.visible ? clockButton.implicitHeight : button.implicitHeight

  Connections {
    target: root.svc
    function onOpenSerialChanged() {
      root.selectedId = root.svc.openRequest
      root.tab = "launch"
    }
  }

  // ---- helpers ----

  // Launch Library text goes into StyledText (crew rows) only through this.
  function esc(t) {
    return String(t === undefined || t === null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
  }

  function pad2(n) { return (n < 10 ? "0" : "") + n }
  function timed(l) { return !!l && (l.precision === "exact" || l.precision === "rough") }

  // How long after T-0 a launch still counts as "happening now".
  function flightWindow(l) {
    var tl = l && l.timeline || []
    var last = tl.length ? tl[tl.length - 1].t : 0
    return Math.min(Math.max(last + 300, 1200), 3600)
  }

  function tClock(l, compact) {
    if (!l || !l.net) return ""
    if (!timed(l)) return l.netLabel || ""
    var s = Math.round(l.net - nowSec)
    var sign = s > 0 ? "T-" : "T+"
    s = Math.abs(s)
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
    if (compact && !d && !h) return sign + pad2(m) + ":" + pad2(sec)
    if (compact && d) return sign + d + "d " + h + "h"
    return sign + (d ? d + "d " : "") + pad2(h) + ":" + pad2(m) + ":" + pad2(sec)
  }

  function relTime(t) {
    var sign = t < 0 ? "T-" : "T+"
    t = Math.abs(Math.round(t))
    var h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = t % 60
    return sign + (h ? h + ":" + pad2(m) : pad2(m)) + ":" + pad2(s)
  }

  function inText(ts) {
    var s = Math.floor(ts - nowSec)
    if (s <= 0) return "now"
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
    if (d > 0) return "in " + d + "d " + h + "h"
    if (h > 0) return "in " + h + "h " + pad2(m) + "m"
    if (m > 0) return "in " + m + "m"
    return "in " + s + "s"
  }

  function agoText(ts) {
    var s = Math.floor(nowSec - ts)
    if (s < 90) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
  }

  function dayLabel(ts) {
    var d = new Date(ts * 1000), now = new Date(nowMs)
    if (sameDay(d, now)) return "Today"
    if (sameDay(d, new Date(nowMs + 86400000))) return "Tomorrow"
    if (sameDay(d, new Date(nowMs - 86400000))) return "Yesterday"
    return Qt.formatDate(d, "ddd MMM d")
  }

  function timeLabel(ts) { return new Date(ts * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat) }

  function whenLabel(l) {
    if (!l) return ""
    if (!timed(l)) return l.netLabel
    return dayLabel(l.net) + " · " + (l.precision === "rough" ? "~" : "") + timeLabel(l.net)
  }

  function windowLabel(l) {
    if (!timed(l) || !l.windowStart || !l.windowEnd) return ""
    if (l.windowEnd - l.windowStart < 60) return "Instantaneous window"
    return "Window " + timeLabel(l.windowStart) + " – " + timeLabel(l.windowEnd)
  }

  function statusColor(l) {
    if (!l || !l.status) return root.dim
    switch (l.status.id) {
    case 1: return root.go
    case 3: return root.go
    case 4: return root.urgent
    case 5: return root.warn
    case 6: return root.urgent
    case 7: return root.warn
    case 8: return Color.accent
    default: return root.dim
    }
  }

  function statusText(l) {
    if (!l || !l.status) return ""
    switch (l.status.id) {
    case 1: return "GO"
    case 2: return "TBD"
    case 3: return "SUCCESS"
    case 4: return "FAILURE"
    case 5: return "HOLD"
    case 6: return "IN FLIGHT"
    case 7: return "PARTIAL"
    case 8: return "TBC"
    default: return (l.status.abbrev || "").toUpperCase()
    }
  }

  function vehicleColor(l) {
    if (!l) return Color.accent
    return l.vehicle === "starship" ? "#c0c6d0" : l.vehicle === "heavy" ? "#e8a33d" : Color.accent
  }

  function img(name) { return name && svc && svc.imgDir ? "file://" + svc.imgDir + "/" + name : "" }

  function ordinal(n) {
    n = Number(n)
    var s = ["th", "st", "nd", "rd"], v = n % 100
    return n + (s[(v - 20) % 10] || s[v] || s[0])
  }

  function days(sec) {
    if (!sec) return ""
    var d = Math.floor(sec / 86400)
    return d >= 1 ? d + "-day" : Math.round(sec / 3600) + "-hour"
  }

  function landingText(b) {
    var land = b.landing
    if (!land) return ""
    if (land.type === "EXP" || !land.attempt) return "Expended"
    var res = land.success === true ? "  " + root.checkGlyph : land.success === false ? "  " + root.crossGlyph : ""
    if (land.type === "ASDS") return "Droneship " + land.where + res
    if (land.type === "RTLS") return "Lands at " + land.where + res
    return (land.whereName || land.where) + res
  }

  function boosterSummary(l) {
    return (l.boosters || []).filter(function(b) { return !!b.serial }).map(function(b) {
      var land = b.landing
      var mark = !land || !land.attempt ? " exp" : land.success === true ? " ✓ " + land.where : land.success === false ? " ✗ " + land.where : " → " + land.where
      return b.serial + (b.flight ? "-" + b.flight : "") + mark
    }).join("  ")
  }

  function crewOf(l) {
    var out = []
    ;(l && l.spacecraft || []).forEach(function(s) { out = out.concat(s.crew || []) })
    return out
  }

  // The event the mission clock is on, and the one after it.
  function timelineState(l) {
    var tl = l && l.timeline || []
    if (!tl.length || !timed(l)) return { current: -1, next: tl.length ? 0 : -1, T: 0 }
    var T = l.phase === "done" ? 1e9 : nowSec - l.net
    var cur = -1
    for (var i = 0; i < tl.length; i++) if (tl[i].t <= T) cur = i
    return { current: cur, next: cur + 1 < tl.length ? cur + 1 : -1, T: T }
  }

  function currentEventLabel(l) {
    var s = timelineState(l)
    if (s.current < 0 || l.net > nowSec) return ""
    return l.timeline[s.current].label
  }

  function playable(l) {
    return (l && l.videos || []).filter(function(v) { return v.playable && !v.stale })
  }

  function liftoffVideo(l) {
    var vs = (l && l.videos || []).filter(function(v) { return v.playable && v.liftoffAt })
    return vs.length ? vs[0] : null
  }

  function watch(l, opts) {
    if (svc && l) svc.watch(l.id, opts || {})
  }

  function summary() {
    if (!svc) return "SERVICE NOT LOADED"
    if (svc.lastError) return svc.lastError.toUpperCase()
    if (st.playerError) return st.playerError.toUpperCase()
    if (!svc.running) return "BACKEND STOPPED"
    if (st.status === "starting" || st.status === "loading") return "LOADING THE MANIFEST…"
    if (st.status === "offline") return "OFFLINE · " + (st.error || "can't reach Launch Library").toUpperCase()
    var bits = []
    var year = recent.length && recent[0].yearCount ? recent[0].yearCount : 0
    if (year) bits.push(year + " LAUNCHES IN " + new Date(recent[0].net * 1000).getFullYear())
    if (st.stats && st.stats.streak) bits.push(st.stats.streak + " SUCCESSES IN A ROW")
    if (st.status === "stale") bits.push("STALE")
    return bits.join("  ·  ")
  }

  function tooltip() {
    var lines = []
    var l = nextLaunch
    if (!l) return "SpaceX Launches"
    lines.push((live ? "● " : "") + l.rocket + " · " + l.name)
    lines.push(whenLabel(l) + "  ·  " + l.pad.short + (l.pad.place ? ", " + l.pad.place : ""))
    if (timed(l)) lines.push(tClock(l) + "  [" + statusText(l) + "]")
    var after = launches.filter(function(x) { return x.id !== l.id && x.net > l.net }).slice(0, 2)
    after.forEach(function(x) { lines.push("then " + x.name + " — " + whenLabel(x)) })
    return lines.join("\n")
  }

  readonly property var tabs: [
    { value: "launch", label: "Launch" },
    { value: "schedule", label: "Schedule" },
    { value: "recent", label: "Recent" },
    { value: "settings", label: "Settings" }
  ]
  readonly property var filters: [
    { value: "all", label: "All" },
    { value: "notable", label: "No Starlink" },
    { value: "starlink", label: "Starlink" }
  ]

  function cycle(options, value, dx) {
    var i = 0
    for (var k = 0; k < options.length; k++) if (options[k].value === value) i = k
    return options[(i + dx + options.length) % options.length].value
  }

  // Step through launches on the Launch tab (or recent ones, if one is open).
  function step(dx) {
    var l = selected
    if (!l) return
    var list = l.phase === "done" ? recent : launches
    var i = -1
    for (var k = 0; k < list.length; k++) if (list[k].id === l.id) i = k
    var j = i + (l.phase === "done" ? -dx : dx)
    if (j >= 0 && j < list.length) {
      selectedId = list[j].id
      descExpanded = false
      showAllStreams = false
    } else if (l.phase === "done" && j < 0 && launches.length) {
      selectedId = ""
    }
  }

  function select(l) {
    selectedId = l && nextLaunch && l.id === nextLaunch.id ? "" : (l ? l.id : "")
    descExpanded = false
    showAllStreams = false
    tab = "launch"
    flick.contentY = 0
  }

  // [{ label, items, coarse }] by local day; vague NETs grouped by their label.
  function scheduleSections() {
    var f = scheduleFilter
    var list = launches.filter(function(l) {
      return f === "all" || (f === "starlink" ? l.starlink : !l.starlink)
    })
    var out = [], byKey = {}
    list.forEach(function(l) {
      var key, label
      if (timed(l) || l.precision === "day") {
        var d = new Date(l.net * 1000)
        if (!timed(l)) d = new Date(l.net * 1000 + d.getTimezoneOffset() * 60000)
        d.setHours(0, 0, 0, 0)
        key = "d" + d.getTime()
        var dl = dayLabel(d.getTime() / 1000)
        label = (dl.indexOf(" ") < 0 ? dl + " · " + Qt.formatDate(d, "ddd MMM d") : dl).toUpperCase()
      } else {
        key = "n" + l.netLabel
        label = l.netLabel.toUpperCase()
      }
      if (!byKey[key]) { byKey[key] = { label: label, items: [], coarse: key[0] === "n" }; out.push(byKey[key]) }
      byKey[key].items.push(l)
    })
    return out
  }

  // ---- bar ----

  BarIconButton {
    id: button
    anchors.fill: parent
    visible: !clockButton.visible
    bar: root.bar
    text: root.rocket
    active: root.live
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.barWatch()
      else if (b === Qt.MiddleButton && root.svc) root.svc.send("refresh")
      else root.toggle()
    }
  }

  WidgetButton {
    id: clockButton
    anchors.fill: parent
    visible: root.barClock
    bar: root.bar
    active: root.live
    text: {
      var l = root.nextLaunch
      if (!l) return ""
      var ev = root.currentEventLabel(l)
      return root.rocket + "  " + root.tClock(l, true) + (ev && ev.length <= 14 ? " · " + ev : "")
    }
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.barWatch()
      else if (b === Qt.MiddleButton && root.svc) root.svc.send("refresh")
      else root.toggle()
    }
  }

  function barWatch() {
    if (player.playing) { if (svc) svc.stop(); return }
    if (playable(nextLaunch).length) watch(nextLaunch)
    else { selectedId = ""; tab = "launch"; open() }
  }

  // Launch-day dot: accent within 24 h, red and breathing while live.
  Rectangle {
    visible: !clockButton.visible && (root.live || root.soon || root.player.playing)
    z: 2
    width: Math.max(5, Math.round(Style.bar.iconFont * 0.42))
    height: width
    radius: width / 2
    color: root.live ? root.urgent : root.player.playing ? root.go : Color.accent
    opacity: root.live ? root.pulse : 1
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Math.max(0, (button.width - Style.bar.iconCanvas) / 2 - width / 3)
    anchors.topMargin: Math.max(1, (button.height - Style.bar.iconCanvas) / 2)
  }

  // ---- panel ----

  KeyboardPanel {
    id: panel
    anchorItem: clockButton.visible ? clockButton : button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

    onOpenChanged: {
      if (!root.svc) return
      root.svc.send("visible", { open: open })
      if (!open) { root.selectedId = ""; root.descExpanded = false; root.showAllStreams = false }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx && root.tab === "launch") root.step(dx)
        else if (dx && root.tab === "schedule") root.scheduleFilter = root.cycle(root.filters, root.scheduleFilter, dx)
        if (dy) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(80)))
      }
      onTextKey: function(t) {
        if (/^[1-4]$/.test(t)) { root.tab = root.tabs[Number(t) - 1].value; flick.contentY = 0 }
        else if (t === "r" && root.svc) root.svc.send("refresh")
        else if (t === "w") root.watch(root.selected)
        else if (t === "f") root.watch(root.selected, { mode: "fullscreen" })
        else if (t === "p") root.watch(root.selected, { mode: "pip" })
        else if (t === "s" && root.svc) root.svc.stop()
        else if (t === "n") root.select(null)
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff; width: Style.space(4) }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "SpaceX Launches"
            meta: root.summary()
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.rocketLaunch
                color: root.live ? root.urgent : Color.accent
                opacity: root.live ? 0.55 + 0.45 * root.pulse : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          ButtonGroup {
            options: root.tabs
            value: root.tab
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.tab = v; flick.contentY = 0 }
          }

          NowPlaying { width: parent.width; visible: root.player.playing }

          Loader {
            width: parent.width
            sourceComponent: root.tab === "launch" ? launchTab
              : root.tab === "schedule" ? scheduleTab
              : root.tab === "recent" ? recentTab : settingsTab
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            wrapMode: Text.WordWrap
            text: "Data: The Space Devs · Launch Library 2" + (root.st.fetchedAt ? " · updated " + root.agoText(root.st.fetchedAt) : "")
              + (root.st.throttledUntil ? " · rate limited " + root.inText(root.st.throttledUntil) : "")
            color: root.dim
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.9
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // ================================================================ tabs

  Component {
    id: launchTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(12)
      readonly property var l: root.selected
      readonly property bool liveNow: !!l && l.phase !== "done" && root.timed(l) && l.net - root.nowSec < 3600 && root.nowSec - l.net < root.flightWindow(l)

      Text {
        textFormat: Text.PlainText
        visible: !parent.l
        width: parent.width
        topPadding: Style.space(24)
        bottomPadding: Style.space(24)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.st.status === "offline" ? "Can't reach Launch Library right now." : "Loading the launch manifest…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // ‹  NEXT LAUNCH  ›
      Item {
        visible: !!parent.l
        width: parent.width
        implicitHeight: Style.space(22)

        PanelActionButton {
          id: prevBtn
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: "‹"
          fontSize: Style.font.title
          foreground: root.fg
          tooltipText: "Earlier (h / ←)"
          onClicked: root.step(-1)
        }
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: {
            var l = root.selected
            if (!l) return ""
            if (l.phase === "done") return "RESULT · " + Qt.formatDate(new Date(l.net * 1000), "MMM d").toUpperCase()
            if (root.nextLaunch && l.id === root.nextLaunch.id) return root.live ? "● HAPPENING NOW" : "NEXT LAUNCH"
            var i = root.launches.indexOf(l)
            return "LAUNCH " + (i + 1) + " OF " + root.launches.length
          }
          color: root.live && root.selected === root.nextLaunch ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.5
        }
        Text {
          textFormat: Text.PlainText
          visible: root.selectedId !== ""
          anchors.right: nextBtn.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: "next ⤴"
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.select(null) }
        }
        PanelActionButton {
          id: nextBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "›"
          fontSize: Style.font.title
          foreground: root.fg
          tooltipText: "Later (l / →)"
          onClicked: root.step(1)
        }
      }

      HeroCard { visible: !!parent.l; width: parent.width; l: parent.l || ({}) }
      WatchBar { visible: !!parent.l; width: parent.width; l: parent.l || ({}) }
      // While it's happening, the timeline comes first.
      Timeline { visible: parent.liveNow && parent.l.timeline.length > 0; width: parent.width; l: parent.l || ({}) }
      FactGrid { visible: !!parent.l; width: parent.width; l: parent.l || ({}) }
      CrewRow { visible: !!parent.l && root.crewOf(parent.l).length > 0; width: parent.width; l: parent.l || ({}) }

      // Mission
      Column {
        visible: !!parent.l && !!parent.l.mission && parent.l.mission.description !== ""
        width: parent.width
        spacing: Style.space(4)
        PanelSectionHeader { text: "MISSION"; foreground: root.fg; fontFamily: root.fontFamily }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: parent.parent.l && parent.parent.l.mission ? parent.parent.l.mission.description : ""
          maximumLineCount: root.descExpanded ? 100 : 4
          elide: Text.ElideRight
          color: root.fg
          opacity: 0.88
          lineHeight: 1.15
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          MouseArea {
            anchors.fill: parent
            enabled: parent.truncated || root.descExpanded
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.descExpanded = !root.descExpanded
          }
        }
      }

      Timeline { visible: !parent.liveNow && !!parent.l && parent.l.timeline && parent.l.timeline.length > 0; width: parent.width; l: parent.l || ({}) }

      // Latest update from the Launch Library editors.
      Rectangle {
        readonly property var u: parent.l && parent.l.updates && parent.l.updates.length ? parent.l.updates[0] : null
        visible: !!u
        width: parent.width
        height: updCol.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: root.wash
        border.width: 1
        border.color: root.faint
        Column {
          id: updCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(10)
          spacing: Style.space(2)
          Text {
            textFormat: Text.PlainText
            text: "LATEST" + (parent.parent.u && parent.parent.u.ts ? "  ·  " + root.agoText(parent.parent.u.ts).toUpperCase() : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: parent.parent.u ? parent.parent.u.text : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  Component {
    id: scheduleTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(8)

      ButtonGroup {
        options: root.filters
        value: root.scheduleFilter
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(v) { root.scheduleFilter = v }
      }

      Text {
        textFormat: Text.PlainText
        readonly property var sections: root.scheduleSections()
        visible: sections.length === 0
        width: parent.width
        topPadding: Style.space(16)
        bottomPadding: Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.st.status === "loading" || root.st.status === "starting" ? "Loading the manifest…" : "Nothing scheduled here."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: root.scheduleSections()
        Column {
          required property var modelData
          width: parent.width
          spacing: Style.space(2)

          Item {
            width: parent.width
            height: dayHeader.implicitHeight + Style.space(8)
            Text {
              id: dayHeader
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(3)
              text: modelData.label
              color: modelData.coarse ? root.dim : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.baseline: dayHeader.baseline
              text: modelData.items.length > 1 ? modelData.items.length + " launches" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: 1
              color: root.faint
            }
          }

          Repeater {
            model: modelData.items
            LaunchRow { required property var modelData; width: parent.width; l: modelData }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: (root.st.hiddenStarlink || 0) > 0
        width: parent.width
        topPadding: Style.space(4)
        wrapMode: Text.WordWrap
        text: root.st.hiddenStarlink + " Starlink launches hidden · turn them on in Settings."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }
      Text {
        textFormat: Text.PlainText
        visible: (root.st.pending || 0) > root.launches.length
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Showing the next " + root.launches.length + " of " + root.st.pending + " SpaceX launches on the books."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }
    }
  }

  Component {
    id: recentTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(10)

      // Season numbers
      Row {
        width: parent.width
        spacing: Style.space(8)
        readonly property real tileW: (width - 2 * spacing) / 3
        StatTile {
          width: parent.tileW
          value: root.recent.length && root.recent[0].yearCount ? String(root.recent[0].yearCount) : "–"
          label: "launches in " + (root.recent.length ? new Date(root.recent[0].net * 1000).getFullYear() : "")
        }
        StatTile {
          width: parent.tileW
          value: root.st.stats && root.st.stats.streak ? String(root.st.stats.streak) : "–"
          label: "successes in a row"
        }
        StatTile {
          width: parent.tileW
          value: root.st.stats && root.st.stats.landingAttempts ? Math.round(100 * root.st.stats.landings / root.st.stats.landingAttempts) + "%" : "–"
          label: root.st.stats && root.st.stats.landings ? root.st.stats.landings + " booster landings" : "booster landings"
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.recent.length === 0
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        topPadding: Style.space(12)
        text: "Loading recent launches…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: root.recent
        ResultRow { required property var modelData; width: parent.width; l: modelData }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "▶ starts the replay 90 seconds before liftoff. Click a launch for its details."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }
    }
  }

  Component {
    id: settingsTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(10)

      PanelSectionHeader { text: "BAR"; foreground: root.fg; fontFamily: root.fontFamily }
      SettingToggle { key: "barCountdown"; label: "Countdown in the bar"; description: "T-minus next to the rocket in the final hour, then the mission clock and current event during flight." }
      SettingToggle { key: "showStarlink"; label: "Show Starlink launches"; description: "Starlink is most of SpaceX's manifest. Off keeps the bar and schedule on everything else." }

      PanelSeparator { foreground: root.fg }
      PanelSectionHeader { text: "ALERTS"; foreground: root.fg; fontFamily: root.fontFamily }
      SettingToggle { key: "notifyRemind"; label: "Launch reminder"; description: "Before a launch that's GO, with a Watch button." }
      Dropdown {
        visible: root.config.notifyRemind !== false
        width: parent.width
        label: "Remind me"
        value: String(root.config.remindMinutes || 30)
        options: [
          { value: "10", label: "10 minutes before" },
          { value: "30", label: "30 minutes before" },
          { value: "60", label: "1 hour before" },
          { value: "120", label: "2 hours before" }
        ]
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("remindMinutes", Number(v)) }
      }
      SettingToggle { key: "notifyLive"; label: "Webcast is live" }
      SettingToggle { key: "notifyLiftoff"; label: "Liftoff" }
      SettingToggle { key: "notifyResult"; label: "Mission result"; description: "Success or failure, and where the booster landed." }
      SettingToggle { key: "notifySlip"; label: "Scrubs and delays"; description: "When a launch in the next three days moves or holds." }
      SettingToggle { key: "starlinkAlerts"; label: "Alerts for Starlink launches too"; checked: root.config.starlinkAlerts === true }

      PanelSeparator { foreground: root.fg }
      PanelSectionHeader { text: "PLAYER"; foreground: root.fg; fontFamily: root.fontFamily }
      Dropdown {
        width: parent.width
        label: "Preferred webcast"
        value: root.config.source || "spacex"
        options: root.st.sources || []
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("source", v) }
      }
      Dropdown {
        width: parent.width
        label: "Open the player as"
        value: root.config.playerMode || "pip"
        options: [
          { value: "pip", label: "Picture-in-picture" },
          { value: "window", label: "Window" },
          { value: "fullscreen", label: "Fullscreen" }
        ]
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("playerMode", v) }
      }
      Dropdown {
        width: parent.width
        label: "Quality"
        value: root.config.quality || "1080"
        options: [
          { value: "480", label: "480p" },
          { value: "720", label: "720p" },
          { value: "1080", label: "1080p (picture-in-picture uses 720p)" },
          { value: "1440", label: "1440p" }
        ]
        foreground: root.fg
        fontFamily: root.fontFamily
        onChanged: function(v) { if (root.svc) root.svc.setConfig("quality", v) }
      }
      Text {
        textFormat: Text.PlainText
        visible: !!root.st.tools && (!root.st.tools.mpv || !root.st.tools.ytdlp)
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Watching needs the mpv and yt-dlp packages" + (root.st.tools && !root.st.tools.mpv ? " (mpv is missing)" : " (yt-dlp is missing)") + ". Without them, webcasts open in the browser."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        spacing: Style.space(8)
        Button {
          text: "Test notification"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: if (root.svc) root.svc.send("test")
        }
        Button {
          text: "Refresh"
          tooltipText: "Refetch the manifest now (r)"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: if (root.svc) root.svc.send("refresh")
        }
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Launch Library allows 15 requests an hour; this widget uses at most " + (root.st.requestBudget || 12) + " (" + (root.st.requestsUsed || 0) + " in the last hour)."
          + "\nKeys: 1–4 tabs · ←/→ launches · w watch · p picture-in-picture · f fullscreen · s stop · n next launch · r refresh"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ================================================================ pieces

  component SettingToggle: Toggle {
    property string key: ""
    width: parent ? parent.width : 0
    foreground: root.fg
    fontFamily: root.fontFamily
    checked: root.config[key] !== false
    onClicked: if (root.svc) root.svc.setConfig(key, !checked)
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property color tint: Color.accent
    property bool solid: false
    property bool pulsing: false
    implicitWidth: pillText.implicitWidth + Style.space(14)
    implicitHeight: pillText.implicitHeight + Style.space(5)
    radius: height / 2
    color: solid ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.16)
    border.width: solid ? 0 : 1
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.55)
    opacity: pulsing ? 0.55 + 0.45 * root.pulse : 1
    Text {
      id: pillText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: pill.text
      color: pill.solid ? "#ffffff" : pill.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption * 0.9
      font.bold: true
      font.letterSpacing: 1
    }
  }

  component StatTile: Rectangle {
    property string value: ""
    property string label: ""
    implicitHeight: tileCol.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: root.wash
    border.width: 1
    border.color: root.faint
    Column {
      id: tileCol
      anchors.centerIn: parent
      width: parent.width - Style.space(12)
      spacing: Style.space(1)
      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: parent.parent.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: parent.parent.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.9
      }
    }
  }

  // Mission photo, patch, status and the big clock.
  component HeroCard: Item {
    id: hero
    property var l: ({})
    readonly property bool done: l.phase === "done"
    readonly property bool flying: !done && root.timed(l) && l.net <= root.nowSec
    implicitHeight: heroCol.implicitHeight + Style.space(32)

    Rectangle {
      id: heroBg
      anchors.fill: parent
      radius: Math.max(Style.cornerRadius, Style.space(6))
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.035)
      border.width: 1
      border.color: hero.l.webcastLive || hero.l.phase === "flight" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.4 + 0.4 * root.pulse) : root.faint
      clip: true

      Image {
        id: photo
        anchors.fill: parent
        source: root.img(hero.l.image)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        opacity: status === Image.Ready ? 0.42 : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
      }
      // Fade the photo into the panel so text stays readable on any theme.
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.25) }
          GradientStop { position: 0.55; color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.78) }
          GradientStop { position: 1.0; color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0.96) }
        }
      }
      Rectangle {
        width: Style.space(3)
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        color: root.vehicleColor(hero.l)
      }
    }

    Image {
      id: patch
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(14)
      width: Style.space(76)
      height: width
      source: root.img(hero.l.patch)
      sourceSize.width: 200
      sourceSize.height: 200
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      visible: status === Image.Ready
    }

    Column {
      id: heroCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(16)
      spacing: Style.space(6)

      Row {
        spacing: Style.space(6)
        Pill {
          text: hero.l.webcastLive && !hero.done ? "● LIVE" : root.statusText(hero.l)
          tint: hero.l.webcastLive && !hero.done ? root.urgent : root.statusColor(hero.l)
          solid: hero.l.webcastLive || hero.l.phase === "flight" || hero.done
          pulsing: !!hero.l.webcastLive && !hero.done
        }
        Pill {
          text: (hero.l.rocket || "").toUpperCase()
          tint: root.vehicleColor(hero.l)
        }
        Pill {
          visible: !!hero.l.starlink
          text: "STARLINK"
          tint: root.dim
        }
      }

      Text {
        width: parent.width - (patch.visible ? patch.width + Style.space(8) : 0)
        topPadding: Style.space(4)
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: hero.l.name || ""
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title * 1.15
        font.bold: true
      }
      Text {
        width: parent.width - (patch.visible ? patch.width + Style.space(8) : 0)
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: (hero.l.rocketFull || "") + (hero.l.pad ? "  ·  " + root.pinGlyph + " " + hero.l.pad.short + (hero.l.pad.place ? ", " + hero.l.pad.place : "") : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        MouseArea {
          anchors.fill: parent
          enabled: !!hero.l.pad && !!hero.l.pad.mapUrl
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (root.svc) root.svc.openUrl(hero.l.pad.mapUrl)
        }
      }

      Item { width: 1; height: Style.space(6) }

      // Big clock, or the outcome once it has flown.
      Text {
        id: bigClock
        textFormat: Text.PlainText
        text: hero.done ? root.statusText(hero.l) : root.tClock(hero.l, false)
        color: hero.done ? root.statusColor(hero.l) : hero.flying ? root.urgent : root.fg
        font.family: root.fontFamily
        font.pixelSize: root.timed(hero.l) || hero.done ? Style.font.displayLarge * 1.25 : Style.font.display
        font.bold: true
        font.letterSpacing: 1
      }
      Text {
        visible: hero.flying && text !== ""
        textFormat: Text.PlainText
        text: {
          var s = root.timelineState(hero.l)
          if (s.current < 0) return ""
          var cur = hero.l.timeline[s.current]
          var nx = s.next >= 0 ? hero.l.timeline[s.next] : null
          return cur.label.toUpperCase() + (nx ? "   →  " + nx.label + " in " + Math.max(0, Math.round(nx.t - s.T)) + "s" : "")
        }
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: {
          if (hero.done) return Qt.formatDateTime(new Date(hero.l.net * 1000), "dddd, MMMM d · ") + root.timeLabel(hero.l.net)
          var w = root.windowLabel(hero.l)
          return root.whenLabel(hero.l) + (w ? "   ·   " + w : "")
        }
        color: root.fg
        opacity: 0.85
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        visible: !!hero.l.failreason && hero.done
        width: parent.width
        wrapMode: Text.WordWrap
        text: hero.l.failreason || ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        visible: !hero.done && !!hero.l.status && (hero.l.status.id === 2 || hero.l.status.id === 8 || hero.l.status.id === 5)
        width: parent.width
        wrapMode: Text.WordWrap
        text: hero.l.status ? hero.l.status.description : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }
    }
  }

  // Watch buttons and webcast choices.
  component WatchBar: Column {
    id: wb
    property var l: ({})
    readonly property bool done: l.phase === "done"
    readonly property var fresh: root.playable(l)
    readonly property var lift: root.liftoffVideo(l)
    readonly property var stale: (l.videos || []).filter(function(v) { return v.playable && v.stale })
    readonly property bool playingThis: root.player.playing && root.player.launchId === l.id
    spacing: Style.space(8)

    Row {
      width: parent.width
      spacing: Style.space(8)

      Button {
        visible: wb.playingThis
        text: "Stop"
        iconText: root.stopGlyph
        bordered: true
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: if (root.svc) root.svc.stop()
      }
      Button {
        visible: !wb.playingThis && (wb.done ? !!wb.lift : wb.fresh.length > 0)
        text: wb.done ? "Watch liftoff" : wb.l.webcastLive ? "Watch live" : "Watch"
        iconText: root.playGlyph
        bordered: true
        active: !!wb.l.webcastLive
        foreground: root.fg
        fontFamily: root.fontFamily
        tooltipText: (wb.done ? "Replay from T-1:30" : "Opens " + (wb.fresh.length ? wb.fresh[0].publisher : "")) + " (w)"
        onClicked: root.watch(wb.l, wb.done ? { liftoff: true, video: wb.lift.url } : {})
      }
      Button {
        visible: !wb.playingThis && wb.done && wb.fresh.length > 0
        text: "Full replay"
        bordered: true
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.watch(wb.l)
      }
      PanelActionButton {
        visible: !wb.playingThis && wb.fresh.length > 0
        iconText: root.pipGlyph
        foreground: root.fg
        bordered: true
        tooltipText: "Picture-in-picture (p)"
        onClicked: root.watch(wb.l, wb.done && wb.lift ? { mode: "pip", liftoff: true, video: wb.lift.url } : { mode: "pip" })
      }
      PanelActionButton {
        visible: !wb.playingThis && wb.fresh.length > 0
        iconText: root.fullGlyph
        foreground: root.fg
        bordered: true
        tooltipText: "Fullscreen (f)"
        onClicked: root.watch(wb.l, wb.done && wb.lift ? { mode: "fullscreen", liftoff: true, video: wb.lift.url } : { mode: "fullscreen" })
      }
      Text {
        textFormat: Text.PlainText
        visible: !wb.playingThis && !wb.done && wb.fresh.length === 0
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        wrapMode: Text.WordWrap
        text: "The webcast link usually appears about an hour before launch. You'll get a notification when it goes live."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Links
    Flow {
      width: parent.width
      spacing: Style.space(12)
      LinkText { visible: !!wb.l.flightclubUrl; text: "Trajectory · Flight Club"; url: wb.l.flightclubUrl || "" }
      LinkText { visible: !!wb.l.infoUrl; text: "Mission page"; url: wb.l.infoUrl || "" }
      LinkText {
        visible: (wb.l.videos || []).length > 0
        text: root.showAllStreams ? "Hide streams" : "All streams (" + (wb.l.videos || []).length + ")"
        url: ""
        onActivated: root.showAllStreams = !root.showAllStreams
      }
    }

    Column {
      visible: root.showAllStreams
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: root.showAllStreams ? (wb.l.videos || []) : []
        StreamRow { required property var modelData; width: parent.width; v: modelData; l: wb.l }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: wb.stale.length > 0 && !wb.done
      width: parent.width
      wrapMode: Text.WordWrap
      text: wb.stale.length ? "Recordings from an earlier attempt (" + Qt.formatDate(new Date(wb.stale[0].start * 1000), "MMM d") + ") are under All streams." : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.italic: true
    }
  }

  component LinkText: Text {
    property string url: ""
    signal activated()
    text: ""
    color: linkMouse.containsMouse ? root.fg : Color.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkMouse.containsMouse
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (parent.url && root.svc) root.svc.openUrl(parent.url)
        parent.activated()
      }
    }
  }

  component StreamRow: Item {
    id: sr
    property var v: ({})
    property var l: ({})
    implicitHeight: srCol.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, srMouse.containsMouse ? 0.08 : 0.03)
    }
    MouseArea {
      id: srMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (sr.v.playable) root.watch(sr.l, { video: sr.v.url, liftoff: sr.l.phase === "done" && !!sr.v.liftoffAt })
        else if (root.svc) root.svc.openUrl(sr.v.url)
      }
    }
    Column {
      id: srCol
      anchors.left: parent.left
      anchors.right: srIcon.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      Row {
        spacing: Style.space(6)
        Text {
          textFormat: Text.PlainText
          text: sr.v.publisher || ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Pill { visible: !!sr.v.live; text: "LIVE"; tint: root.urgent; solid: true; pulsing: true; anchors.verticalCenter: parent.verticalCenter }
        Pill { visible: !!sr.v.official; text: "OFFICIAL"; tint: root.go; anchors.verticalCenter: parent.verticalCenter }
        Pill { visible: !!sr.v.stale; text: "EARLIER ATTEMPT"; tint: root.dim; anchors.verticalCenter: parent.verticalCenter }
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: (sr.v.title || sr.v.url) + (sr.v.playable ? "" : "  ·  opens in browser")
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Text {
      id: srIcon
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: sr.v.playable ? root.playGlyph : root.linkGlyph
      color: srMouse.containsMouse ? Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
  }

  // Booster, orbit, weather, customer, spacecraft, launch count.
  component FactGrid: Grid {
    id: facts
    property var l: ({})
    readonly property var tiles: {
      var out = []
      var l = facts.l
      if (!l || !l.id) return out
      ;(l.boosters || []).forEach(function(b) {
        if (!b.serial) return
        var sub = b.flight ? root.ordinal(b.flight) + " flight" : "First flight"
        if (b.turnaround) sub += " · " + root.days(b.turnaround) + " turnaround"
        out.push({ icon: b.landing && b.landing.type === "ASDS" ? root.shipGlyph : root.rocket,
                   label: b.type === "Core" ? "BOOSTER" : b.type.toUpperCase(),
                   value: b.serial, sub: sub, sub2: root.landingText(b),
                   tint: b.landing && b.landing.success === false ? root.urgent : b.landing && b.landing.success === true ? root.go : root.fg })
      })
      if (l.mission && (l.mission.orbit || l.mission.type))
        out.push({ icon: root.earthGlyph, label: "ORBIT", value: l.mission.orbit || "TBD", sub: l.mission.type, sub2: "" })
      if (l.probability !== null && l.probability !== undefined || l.weather)
        out.push({ icon: root.cloudGlyph, label: "WEATHER",
                   value: l.probability !== null && l.probability !== undefined ? l.probability + "% GO" : "Watch",
                   sub: l.weather || "Forecast from the 45th Weather Squadron", sub2: "",
                   tint: l.probability >= 70 ? root.go : l.probability >= 40 ? root.warn : l.probability !== null && l.probability !== undefined ? root.urgent : root.fg })
      if (l.mission && l.mission.customers && l.mission.customers.length)
        out.push({ icon: root.satGlyph, label: "CUSTOMER", value: l.mission.customers[0], sub: l.mission.customers.slice(1).join(", "), sub2: "" })
      ;(l.spacecraft || []).forEach(function(s) {
        out.push({ icon: root.rocketLaunch, label: "SPACECRAFT", value: (s.config || "Dragon") + (s.serial ? " " + s.serial : ""),
                   sub: s.name && s.name !== s.config ? s.name : "", sub2: s.destination ? "→ " + s.destination : "" })
      })
      if (l.yearCount)
        out.push({ icon: root.flagGlyph, label: l.phase === "done" ? "LAUNCH" : "WILL BE", value: root.ordinal(l.yearCount) + " of " + new Date(l.net * 1000).getFullYear(),
                   sub: l.padYearCount ? root.ordinal(l.padYearCount) + " from " + l.pad.short + " this year" : "",
                   sub2: l.padTurnaround ? "Pad turnaround " + root.days(l.padTurnaround).replace("-", " ") + "s" : "" })
      return out
    }
    visible: tiles.length > 0
    columns: 2
    columnSpacing: Style.space(8)
    rowSpacing: Style.space(8)
    readonly property real tileW: (width - columnSpacing) / 2

    Repeater {
      model: facts.tiles
      Rectangle {
        id: tile
        required property var modelData
        width: facts.tileW
        height: Math.max(tileInner.implicitHeight + Style.space(18), Style.space(70))
        radius: Style.cornerRadius
        color: root.wash
        border.width: 1
        border.color: root.faint

        Column {
          id: tileInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          spacing: Style.space(2)
          Text {
            textFormat: Text.PlainText
            text: tile.modelData.icon + "  " + tile.modelData.label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.9
            font.bold: true
            font.letterSpacing: 1
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: tile.modelData.value
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: tile.modelData.tint || root.fg
            font.family: root.fontFamily
            font.pixelSize: tile.modelData.value.length > 16 ? Style.font.body : Style.font.heading
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            visible: !!tile.modelData.sub
            width: parent.width
            text: tile.modelData.sub || ""
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            visible: !!tile.modelData.sub2
            width: parent.width
            text: tile.modelData.sub2 || ""
            elide: Text.ElideRight
            color: root.fg
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component CrewRow: Column {
    id: crew
    property var l: ({})
    spacing: Style.space(6)
    PanelSectionHeader { text: "CREW"; foreground: root.fg; fontFamily: root.fontFamily }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: root.crewOf(crew.l)
        Rectangle {
          required property var modelData
          height: crewText.implicitHeight + Style.space(12)
          width: crewText.implicitWidth + Style.space(20)
          radius: Style.cornerRadius
          color: root.wash
          border.width: 1
          border.color: root.faint
          Text {
            id: crewText
            anchors.centerIn: parent
            textFormat: Text.StyledText
            text: "<b>" + root.esc(modelData.name) + "</b>  <font color='" + root.dim + "'>" + root.esc(modelData.role) + (modelData.agency ? " · " + root.esc(modelData.agency) : "") + "</font>"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Countdown and flight events, lit up against the mission clock.
  component Timeline: Column {
    id: tl
    property var l: ({})
    readonly property var s: root.timelineState(l)
    readonly property bool clockRunning: root.timed(l) && l.phase !== "done" && Math.abs(l.net - root.nowSec) < 4 * 3600
    readonly property var events: l.timeline || []
    // Around the clock: two events back, five ahead. Otherwise everything.
    readonly property int first: clockRunning && !root.timelineAll ? Math.max(0, Math.min(s.current - 2, events.length - 8)) : 0
    readonly property int last: clockRunning && !root.timelineAll ? Math.min(events.length, first + 8) : events.length
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: tlHead.implicitHeight
      PanelSectionHeader {
        id: tlHead
        text: "COUNTDOWN & FLIGHT"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: tlHead.verticalCenter
        visible: tl.clockRunning
        text: root.tClock(tl.l, false)
        color: tl.l.net <= root.nowSec ? root.urgent : Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Repeater {
      model: tl.events
      Item {
        id: ev
        required property var modelData
        required property int index
        visible: index >= tl.first && index < tl.last
        readonly property bool passed: tl.l.phase === "done" || (tl.clockRunning && index <= tl.s.current)
        readonly property bool current: tl.clockRunning && index === tl.s.current
        readonly property bool upNext: tl.clockRunning && index === tl.s.next
        readonly property bool liftoff: modelData.t === 0
        width: tl.width
        height: Math.max(evLabel.implicitHeight, Style.space(14)) + Style.space(8)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: ev.upNext ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            : ev.current ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10) : "transparent"
        }
        Text {
          id: evTime
          textFormat: Text.PlainText
          x: Style.space(6)
          width: Style.space(78)
          anchors.verticalCenter: parent.verticalCenter
          text: ev.modelData.t === 0 ? "T-0" : root.relTime(ev.modelData.t)
          color: ev.passed && !ev.current ? root.dim : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: ev.liftoff || ev.current || ev.upNext
        }
        // Rail
        Rectangle {
          x: evTime.x + evTime.width + Style.space(4)
          width: 2
          height: parent.height
          color: ev.passed ? (tl.l.phase === "done" ? root.go : root.urgent) : root.faint
          opacity: 0.6
        }
        Rectangle {
          id: dot
          x: evTime.x + evTime.width + Style.space(4) - width / 2 + 1
          anchors.verticalCenter: parent.verticalCenter
          width: ev.liftoff || ev.current ? Style.space(10) : Style.space(7)
          height: width
          radius: width / 2
          color: ev.current ? root.urgent : ev.passed ? (tl.l.phase === "done" ? root.go : root.urgent) : ev.upNext ? Color.accent : root.surface
          border.width: ev.passed || ev.current ? 0 : 1
          border.color: ev.upNext ? Color.accent : root.dim
          opacity: ev.current ? 0.6 + 0.4 * root.pulse : 1
        }
        Text {
          id: evLabel
          textFormat: Text.PlainText
          anchors.left: dot.right
          anchors.leftMargin: Style.space(10)
          anchors.right: evIn.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: ev.modelData.label
          elide: Text.ElideRight
          color: ev.passed && !ev.current ? root.dim : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: ev.liftoff || ev.current || ev.upNext
          HoverHandler { id: evHover }
          ToolTip.visible: evHover.hovered && !!ev.modelData.description
          ToolTip.text: ev.modelData.description
          ToolTip.delay: 400
        }
        Text {
          id: evIn
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: ev.upNext ? "in " + Math.max(0, Math.round(ev.modelData.t - tl.s.T)) + "s"
            : ev.current ? "NOW"
            : ev.passed && tl.l.phase !== "done" ? root.checkGlyph : ""
          color: ev.current ? root.urgent : ev.upNext ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    LinkText {
      visible: tl.clockRunning && tl.events.length > 8
      text: root.timelineAll ? "Follow the clock" : "All " + tl.events.length + " events"
      onActivated: root.timelineAll = !root.timelineAll
    }
  }

  component LaunchRow: Item {
    id: row
    property var l: ({})
    readonly property bool isNext: !!root.nextLaunch && root.nextLaunch.id === l.id
    implicitHeight: rowCol.implicitHeight + Style.space(12)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: row.isNext ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, rowMouse.containsMouse ? 0.20 : 0.11)
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, rowMouse.containsMouse ? 0.07 : 0)
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    Rectangle {
      width: Style.space(3)
      height: parent.height - Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      radius: width / 2
      color: root.vehicleColor(row.l)
      opacity: row.l.starlink ? 0.35 : 1
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.select(row.l)
    }

    Text {
      id: rowTime
      textFormat: Text.PlainText
      x: Style.space(10)
      width: Style.space(66)
      anchors.verticalCenter: parent.verticalCenter
      text: root.timed(row.l) ? (row.l.precision === "rough" ? "~" : "") + root.timeLabel(row.l.net) : row.l.precision === "day" ? "TBD" : "—"
      color: root.timed(row.l) ? root.fg : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: row.isNext
    }

    Image {
      id: rowPatch
      anchors.left: rowTime.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(26)
      height: width
      source: root.img(row.l.patch)
      sourceSize.width: 64
      sourceSize.height: 64
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      opacity: status === Image.Ready ? 1 : 0
    }
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: rowPatch
      visible: rowPatch.status !== Image.Ready
      text: row.l.starlink ? root.satGlyph : root.rocket
      color: root.vehicleColor(row.l)
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rowCol
      anchors.left: rowPatch.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowRight.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.l.name || ""
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isNext || !row.l.starlink
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: (row.l.rocket || "") + " · " + (row.l.pad ? row.l.pad.short + (row.l.pad.place ? ", " + row.l.pad.place : "") : "")
          + (root.boosterSummary(row.l) ? " · " + root.boosterSummary(row.l) : "")
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Column {
      id: rowRight
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Pill {
        anchors.right: parent.right
        text: row.l.webcastLive ? "● LIVE" : root.statusText(row.l)
        tint: row.l.webcastLive ? root.urgent : root.statusColor(row.l)
        solid: !!row.l.webcastLive
        pulsing: !!row.l.webcastLive
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        visible: root.timed(row.l)
        text: row.l.net > root.nowSec ? root.inText(row.l.net) : root.tClock(row.l, true)
        color: row.isNext ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: row.isNext
      }
    }
  }

  component ResultRow: Item {
    id: rr
    property var l: ({})
    readonly property var lift: root.liftoffVideo(l)
    implicitHeight: rrCol.implicitHeight + Style.space(14)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, rrMouse.containsMouse ? 0.07 : 0.03)
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    MouseArea {
      id: rrMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.select(rr.l)
    }

    Image {
      id: rrPatch
      x: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      height: width
      source: root.img(rr.l.patch)
      sourceSize.width: 80
      sourceSize.height: 80
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      opacity: status === Image.Ready ? 1 : 0
    }
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: rrPatch
      visible: rrPatch.status !== Image.Ready
      text: rr.l.starlink ? root.satGlyph : root.rocket
      color: root.vehicleColor(rr.l)
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rrCol
      anchors.left: rrPatch.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rrPlay.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Row {
        spacing: Style.space(6)
        Pill { text: root.statusText(rr.l); tint: root.statusColor(rr.l); anchors.verticalCenter: parent.verticalCenter }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: Qt.formatDate(new Date(rr.l.net * 1000), "ddd MMM d").toUpperCase() + "  ·  " + (rr.l.rocket || "").toUpperCase()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 0.5
        }
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: rr.l.name || ""
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: (rr.l.pad ? rr.l.pad.short + " · " : "") + root.boosterSummary(rr.l)
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    PanelActionButton {
      id: rrPlay
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      visible: !!rr.lift || root.playable(rr.l).length > 0
      iconText: root.playGlyph
      foreground: root.fg
      bordered: true
      tooltipText: rr.lift ? "Watch liftoff (" + rr.lift.publisher + ")" : "Watch the replay"
      onClicked: root.watch(rr.l, rr.lift ? { liftoff: true, video: rr.lift.url } : {})
    }
  }

  component NowPlaying: Rectangle {
    id: np
    implicitHeight: npRow.implicitHeight + Style.space(14)
    radius: Style.cornerRadius
    color: Qt.rgba(root.go.r, root.go.g, root.go.b, 0.10)
    border.width: 1
    border.color: Qt.rgba(root.go.r, root.go.g, root.go.b, 0.45)

    Row {
      id: npRow
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.playGlyph
        color: root.go
        opacity: 0.55 + 0.45 * root.pulse
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        Text {
          textFormat: Text.PlainText
          text: "NOW PLAYING" + (root.player.liftoff ? " · LIFTOFF REPLAY" : "")
          color: root.go
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption * 0.9
          font.bold: true
          font.letterSpacing: 1
        }
        Text {
          textFormat: Text.PlainText
          width: np.width - Style.space(150)
          text: (root.player.name || "") + "  ·  " + (root.player.publisher || "")
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      PanelActionButton {
        iconText: root.fullGlyph
        foreground: root.fg
        tooltipText: "Toggle fullscreen"
        onClicked: if (root.svc) root.svc.playerCommand(["cycle", "fullscreen"])
      }
      PanelActionButton {
        iconText: String.fromCodePoint(0xF075F)
        foreground: root.fg
        tooltipText: "Mute"
        onClicked: if (root.svc) root.svc.playerCommand(["cycle", "mute"])
      }
      PanelActionButton {
        iconText: root.stopGlyph
        foreground: root.fg
        tooltipText: "Stop (s)"
        onClicked: if (root.svc) root.svc.stop()
      }
    }
  }
}
