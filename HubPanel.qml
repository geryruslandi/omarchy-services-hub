import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Services Hub — registered user and system services in one themed overlay
// card. Bar-free: open it by searching "Services hub" in the launcher, from
// the root-menu row, or `omarchy-shell shell toggle geryruslandi.services-hub`.
//
// Ported from the MIT-licensed gabepsilva/omarchy-user-services (Panel.qml):
// start/stop switch per service, real RAM and VRAM figures, a details view
// with restart, start-at-login, PID/uptime/CPU/tasks and coloured live logs.
// Extended here with a service registry (user or system scope), an
// add-service form, and an optional per-unit polkit whitelist for system
// services. No favorites.
//
// Hosted as an overlay plugin (alanfortlink.clipboard pattern): the root
// owns a PanelWindow and the shell's generic toggle/summon/hide/call drive
// open()/close() and the public functions below.

Item {
  id: root

  // ---- Overlay contract (used by the shell's plugin loader)
  property bool opened: false

  function open() {
    root.opened = true
    root.detailsKey = ""
    root.formOpen = false
    root.query = ""
    root.cursorIndex = 0
    root.cursorActive = false
    root.refresh()
    root.refreshPolkitStatus()
    if (root.registry.length === 0) root.openForm()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  // After a pkexec/polkit dialog closes (the shell's own agent dialog
  // grabbed exclusive keyboard while it was up), the compositor does not
  // always hand the keyboard back to this surface. Re-assert the layer's
  // keyboard interactivity and refocus the key catcher so navigation keeps
  // working right after a password prompt.
  function refocusKeyboard() {
    if (!root.opened) return
    panelWindow.WlrLayershell.keyboardFocus = WlrKeyboardFocus.None
    panelWindow.WlrLayershell.keyboardFocus = WlrKeyboardFocus.Exclusive
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ---- Identity and paths
  readonly property string pluginId: "geryruslandi.services-hub"
  // Bumped with every behavioural change; logged on load so the journal
  // always shows whether the running panel is stale.
  readonly property string buildStamp: "2026-10-25T21:10"
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string statePath: Color.stateHome + "/omarchy/services-hub.json"
  readonly property string polkitCandidatePath: Color.stateHome + "/omarchy/services-hub-polkit.rules"

  function scriptPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }
  readonly property string cappedScript: scriptPath("capped.sh")
  readonly property string memoryScript: scriptPath("memory.sh")
  readonly property string vramScript: scriptPath("vram.sh")
  readonly property string logsScript: scriptPath("logs.sh")
  readonly property string polkitScript: scriptPath("polkit.sh")
  readonly property string setupScript: scriptPath("setup.sh")

  function bounded(seconds, argv) {
    return Model.bounded(seconds, root.cappedScript, argv)
  }

  // ---- Theme tokens (menu surface, like the clipboard card)
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property int cornerRadius: Style.cornerRadius

  // ---- Persisted state (registry + settings + polkit bookkeeping)
  property var stateObj: Model.defaultState()
  readonly property var registry: stateObj.registry || []
  readonly property bool showInactive: stateObj.settings.showInactive === true
  readonly property bool hideAutostart: stateObj.settings.hideAutostart === true
  readonly property int refreshIntervalSec: Math.max(2, Number(stateObj.settings.refreshIntervalSec) || 5)
  property string userName: ""

  function persistState() {
    stateFile.setText(JSON.stringify(root.stateObj, null, 2) + "\n")
  }

  function setSettings(patch) {
    var next = JSON.parse(JSON.stringify(root.stateObj))
    for (var k in patch) next.settings[k] = patch[k]
    root.stateObj = Model.normalizeState(next)
    root.persistState()
  }

  // ---- Registry data merged with what systemd knows, per scope
  property var loadedUserUnits: []
  property var loadedSystemUnits: []
  property var userFileStates: ({})
  property var systemFileStates: ({})
  property bool loaded: false
  property string loadError: ""
  property string query: ""
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var userUnits: Model.withInstalledUnits(loadedUserUnits, userFileStates)
  readonly property var systemUnits: Model.withInstalledUnits(loadedSystemUnits, systemFileStates)
  readonly property var userUnitsByName: Model.unitMap(userUnits)
  readonly property var systemUnitsByName: Model.unitMap(systemUnits)

  // One row per registry entry; both scopes merged, failed first.
  readonly property var registryRows: Model.registeredRows(registry, userUnitsByName, systemUnitsByName)
  readonly property var visibleRows: Model.filterRegistered(registryRows, {
    query: root.query,
    showInactive: root.showInactive,
    hideAutostart: root.hideAutostart
  })
  readonly property int runningCount: {
    var n = 0
    for (var i = 0; i < registryRows.length; i++) if (Model.isRunning(registryRows[i].unitData)) n++
    return n
  }
  readonly property int failedCount: {
    var n = 0
    for (var i = 0; i < registryRows.length; i++) if (Model.isFailed(registryRows[i].unitData)) n++
    return n
  }

  // ---- Busy / action feedback
  property string busyKey: "" // "<scope>:<unit>"
  property string busyVerb: ""
  property string actionStatus: ""
  property bool actionFailed: false

  // ---- RAM per unit, per scope (cgroups), VRAM per unit (covers both)
  property var memoryUserByUnit: ({})
  property var memorySystemByUnit: ({})
  property var vramByUnit: ({})

  function memoryOf(row) {
    if (!row) return undefined
    var map = row.scope === "system" ? root.memorySystemByUnit : root.memoryUserByUnit
    return map[row.unit]
  }

  // ---- Details view
  property string detailsKey: "" // "<scope>:<unit>"
  readonly property bool detailsOpen: detailsKey !== ""
  property string detailsScope: ""
  property string detailsUnit: ""
  readonly property var detailsData: detailsOpen
    ? Model.registryUnit(detailsScope === "system" ? root.systemUnitsByName : root.userUnitsByName, detailsUnit)
    : null
  property string enableState: ""
  property string enableError: ""
  property var stats: ({})
  property string logsText: ""
  property bool logsLoaded: false
  property var logPalette: ({})
  readonly property var logColors: ({
    foreground: String(root.foreground),
    dim: String(root.dim),
    error: String(root.urgent),
    warning: root.logPalette[3] || "#d7a94b",
    palette: root.logPalette
  })
  property real nowSec: Date.now() / 1000
  readonly property bool detailsRunning: Model.isRunning(detailsData)
  readonly property var activeSince: Model.unixTimestamp(stats.ActiveEnterTimestamp)

  // ---- Add-service form
  property bool formOpen: false
  property string formScope: "" // "" until the user picks user/system
  property string formUnit: ""
  property string formError: ""
  readonly property var formOptions: formScope === "" ? [] : Model.dropdownItems(
    formScope === "system" ? root.systemFileStates : root.userFileStates, root.registry, root.formScope)

  // ---- Polkit whitelist
  property var polkitInstalled: null // {present, signature} from polkit.sh status
  property bool polkitAutoOffered: false // once per shell session
  // Whitelist covers registered system units AND their socket/timer
  // companions — without them a stopped service is restarted by socket
  // activation, and stopping the socket itself would prompt for a password.
  readonly property var polkitUnits: Model.managedUnits(registry, "system")
  readonly property string polkitSignature: Model.unitSetSignature(polkitUnits)
  readonly property bool polkitNeedsSync: Model.polkitNeedsSync(stateObj, polkitUnits, polkitInstalled)
  readonly property bool polkitBusy: polkitSyncProcess.running || polkitRemoveProcess.running

  function refreshPolkitStatus() {
    if (polkitStatusProcess.running) return
    polkitStatusProcess.command = ["sh", root.polkitScript, "status"]
    polkitStatusProcess.running = true
  }

  function startPolkitSync() {
    if (root.polkitBusy) return
    var names = root.polkitUnits
    if (names.length === 0) return
    rulesCandidateFile.setText(Model.generatePolkitRules(root.userName, names, root.polkitSignature))
    polkitSyncProcess.command = ["pkexec", "sh", root.polkitScript, "sync", root.polkitCandidatePath]
    polkitSyncProcess.running = true
  }

  function maybeAutoPolkit() {
    if (!root.opened) return
    if (!root.polkitNeedsSync) return
    if (root.stateObj.polkit.declinedSessionOnly) return
    if (root.polkitAutoOffered) return
    root.polkitAutoOffered = true
    Quickshell.execDetached(["notify-send", "-a", "Services Hub", "Services Hub — polkit whitelist",
      "Updating the whitelist for your registered system services. You may be asked for your password."])
    root.startPolkitSync()
  }

  function polkitRemoved() {
    var next = JSON.parse(JSON.stringify(root.stateObj))
    next.polkit.signature = ""
    next.polkit.syncedAt = ""
    root.stateObj = Model.normalizeState(next)
    root.persistState()
    root.actionStatus = "Polkit whitelist removed."
    root.actionFailed = false
    statusTimer.restart()
  }

  // ---- Confirm dialog (critical units, removals)
  property bool confirmOpen: false
  property string confirmMessage: ""
  property string confirmLabel: "Confirm"
  property var pendingConfirm: null

  function askConfirm(message, confirmText, action) {
    root.confirmMessage = message
    root.confirmLabel = confirmText
    root.pendingConfirm = action
    root.confirmOpen = true
  }

  // ---- Data refresh
  function refresh() {
    refreshLists()
    if (root.opened && !root.detailsOpen) refreshMemory()
  }

  function refreshLists() {
    if (!listUserProcess.running) {
      listUserProcess.command = root.bounded(Model.TIMEOUT_SEC.read,
        ["systemctl", "--user", "list-units", "--type=service", "--all", "--output=json", "--no-pager"])
      listUserProcess.running = true
    }
    if (!listSystemProcess.running) {
      listSystemProcess.command = root.bounded(Model.TIMEOUT_SEC.read,
        ["systemctl", "list-units", "--type=service", "--all", "--output=json", "--no-pager"])
      listSystemProcess.running = true
    }
    if (root.opened) refreshUnitFiles()
  }

  function refreshUnitFiles() {
    if (!unitFilesUserProcess.running) {
      unitFilesUserProcess.command = root.bounded(Model.TIMEOUT_SEC.read,
        ["systemctl", "--user", "list-unit-files", "--type=service", "--output=json", "--no-pager"])
      unitFilesUserProcess.running = true
    }
    if (!unitFilesSystemProcess.running) {
      unitFilesSystemProcess.command = root.bounded(Model.TIMEOUT_SEC.read,
        ["systemctl", "list-unit-files", "--type=service", "--output=json", "--no-pager"])
      unitFilesSystemProcess.running = true
    }
  }

  function refreshMemory() {
    if (!memUserProcess.running) {
      memUserProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["sh", root.memoryScript, "user"])
      memUserProcess.running = true
    }
    if (!memSystemProcess.running) {
      memSystemProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["sh", root.memoryScript, "system"])
      memSystemProcess.running = true
    }
    if (!vramProcess.running) {
      vramProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["bash", root.vramScript])
      vramProcess.running = true
    }
  }

  function refreshUnitMemory() {
    if (!detailsOpen) return
    if (!memUnitProcess.running) {
      memUnitProcess.unit = detailsUnit
      memUnitProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["sh", root.memoryScript, detailsScope, detailsUnit])
      memUnitProcess.running = true
    }
    if (!vramUnitProcess.running) {
      vramUnitProcess.unit = detailsUnit
      vramUnitProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["bash", root.vramScript, detailsUnit])
      vramUnitProcess.running = true
    }
  }

  function refreshStats() {
    if (!detailsOpen || statsProcess.running) return
    statsProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["systemctl"].concat(
      detailsScope === "user" ? ["--user"] : [],
      ["show", "--timestamp=unix", "--no-pager", "-p",
       "MainPID,ActiveEnterTimestamp,TasksCurrent,CPUUsageNSec,NRestarts", "--", detailsUnit]))
    statsProcess.running = true
  }

  function refreshEnableState() {
    if (!detailsOpen || enableStateProcess.running) return
    enableStateProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["systemctl"].concat(
      detailsScope === "user" ? ["--user"] : [],
      ["is-enabled", "--", detailsUnit]))
    enableStateProcess.running = true
  }

  function refreshLogs() {
    if (!detailsOpen || logsProcess.running) return
    logsProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["sh", root.logsScript, detailsScope, detailsUnit, "300", "65536"])
    logsProcess.running = true
  }

  // ---- Actions
  property string lastActionVerb: ""
  property string lastActionScope: ""
  property string lastActionUnit: ""

  // Companion socket/timer units stopped alongside their service (so the
  // stop sticks), remembered per service key; a later start brings them back.
  property var stoppedCompanions: ({})

  // The companion chain: a queue of { unit, verb, probe } steps; probe steps
  // check is-active first and only act when the unit is active.
  property var chainQueue: []
  property string chainScope: ""

  function systemctlArgs(scope, verb, unit) {
    // System scope runs systemctl as the user: systemd's D-Bus call triggers
    // the manage-units/manage-unit-files polkit check, which the generated
    // whitelist covers. pkexec would sit in front with its own
    // org.freedesktop.policykit.exec action, which the whitelist cannot and
    // should not grant — that was why every action kept prompting.
    var argv = scope === "system" ? ["systemctl"] : ["systemctl", "--user"]
    return argv.concat([verb, "--", unit])
  }

  function runAction(verb, scope, unit) {
    if (!unit || unit === "") return
    if (actionProcess.running) return
    root.lastActionVerb = verb
    root.lastActionScope = scope
    root.lastActionUnit = unit
    root.busyKey = Model.scopeKey(scope, unit)
    root.busyVerb = verb
    root.actionStatus = ""
    root.actionFailed = false
    var seconds = scope === "system" ? Model.TIMEOUT_SEC.systemAction : Model.TIMEOUT_SEC.action
    actionProcess.command = root.bounded(seconds, root.systemctlArgs(scope, verb, unit))
    actionProcess.running = true
  }

  // Runs after every finished systemctl action: drives the socket/timer
  // companion chain so a stop keeps the service down and a start brings
  // back what we stopped.
  function afterAction() {
    var key = Model.scopeKey(root.lastActionScope, root.lastActionUnit)

    // A completed companion step: continue the chain.
    if (root.chainQueue.length > 0 && root.chainScope === root.lastActionScope
        && root.chainQueue[0].unit === root.lastActionUnit) {
      root.chainQueue.shift()
      chainNext()
      return
    }

    // A completed service stop: queue its companions to stop (probe first).
    if (root.lastActionVerb === "stop" && /\.service$/.test(root.lastActionUnit)) {
      var steps = []
      var companions = Model.companionUnits(root.lastActionUnit)
      for (var i = 0; i < companions.length; i++)
        steps.push({ unit: companions[i], verb: "stop", probe: true })
      root.chainQueue = steps
      root.chainScope = root.lastActionScope
      chainNext()
      return
    }

    // A completed service start: restore what this session stopped.
    if (root.lastActionVerb === "start" && /\.service$/.test(root.lastActionUnit)) {
      var remembered = root.stoppedCompanions[key] || []
      var restore = []
      for (var r = 0; r < remembered.length; r++)
        restore.push({ unit: remembered[r], verb: "start", probe: false })
      delete root.stoppedCompanions[key]
      if (restore.length === 0) return
      root.chainQueue = restore
      root.chainScope = root.lastActionScope
      chainNext()
    }
  }

  function chainNext() {
    if (root.chainQueue.length === 0) return
    var head = root.chainQueue[0]
    if (!head.probe) {
      runAction(head.verb, root.chainScope, head.unit)
      return
    }
    if (companionProbeProcess.running) return
    companionProbeProcess.command = root.bounded(Model.TIMEOUT_SEC.read, ["systemctl"].concat(
      root.chainScope === "user" ? ["--user"] : [],
      ["is-active", "--", head.unit]))
    companionProbeProcess.running = true
  }

  // Start/stop via the row switch; restart via button or `r`.
  function toggleRow(row) {
    if (!row) return
    var running = Model.isRunning(row.unitData)
    if (!running) { runAction("start", row.scope, row.unit); return }
    if (Model.isCritical(row.unit)) {
      askConfirm("Stop " + Model.displayName(row.unit) + "? It keeps your desktop session working — stopping it can break things until it is restarted.", "Stop", function() {
        runAction("stop", row.scope, row.unit)
      })
      return
    }
    runAction("stop", row.scope, row.unit)
  }

  function restartRow(row) {
    if (!row) return
    if (Model.isCritical(row.unit)) {
      askConfirm("Restart " + Model.displayName(row.unit) + "? It keeps your desktop session working.", "Restart", function() {
        runAction("restart", row.scope, row.unit)
      })
      return
    }
    runAction("restart", row.scope, row.unit)
  }

  function setEnabled(on) {
    if (!detailsOpen || enableProcess.running || !Model.canToggleEnable(enableState)) return
    var scope = detailsScope, unit = detailsUnit
    root.enableError = ""
    var seconds = scope === "system" ? Model.TIMEOUT_SEC.systemAction : Model.TIMEOUT_SEC.action
    // Flip optimistically so the knob throws on the click; the exit handler
    // re-reads the real state either way.
    root.enableState = on ? "enabled" : "disabled"
    enableProcess.verb = on ? "enable" : "disable"
    enableProcess.command = root.bounded(seconds, root.systemctlArgs(scope, enableProcess.verb, unit))
    enableProcess.running = true
  }

  function followLogs() {
    if (!detailsOpen) return
    var unitArg = detailsScope === "user" ? "--user-unit=" + detailsUnit : "--unit=" + detailsUnit
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec",
      "--app-id=org.omarchy.terminal", "--title=" + Model.displayName(detailsUnit) + " logs",
      "-e", "journalctl", unitArg, "-f", "-n", "200"])
  }

  // ---- Registry mutations
  function addService(scope, unit) {
    var res = Model.addToRegistry(root.registry, scope, unit)
    if (res.error !== "") { root.formError = res.error; return false }
    var next = JSON.parse(JSON.stringify(root.stateObj))
    next.registry = res.list
    root.stateObj = Model.normalizeState(next)
    root.persistState()
    root.formError = ""
    root.refreshLists()
    if (scope === "system") {
      root.refreshPolkitStatus()
      root.maybeAutoPolkit()
    }
    return true
  }

  function removeService(scope, unit) {
    var key = Model.scopeKey(scope, unit)
    var next = JSON.parse(JSON.stringify(root.stateObj))
    next.registry = Model.removeFromRegistry(root.registry, scope, unit)
    root.stateObj = Model.normalizeState(next)
    root.persistState()
    if (root.detailsKey === key) root.closeDetails()
    root.refreshPolkitStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function requestRemove(row) {
    if (!row) return
    askConfirm("Remove " + Model.displayName(row.unit) + " (" + row.scope + ") from the hub? The service itself is not touched.", "Remove", function() {
      root.removeService(row.scope, row.unit)
    })
  }

  // ---- Details open/close
  function openDetails(scope, unit) {
    if (!unit) return
    themeColors.reload()
    root.detailsScope = scope
    root.detailsUnit = unit
    root.detailsKey = Model.scopeKey(scope, unit)
    root.enableState = ""
    root.enableError = ""
    root.logsText = ""
    root.logsLoaded = false
    if (logsFlick) logsFlick.pinned = true
    root.stats = ({})
    root.nowSec = Date.now() / 1000
    root.refreshStats()
    root.refreshEnableState()
    root.refreshLogs()
    root.refreshUnitMemory()
  }

  function closeDetails() {
    root.detailsKey = ""
    root.detailsScope = ""
    root.detailsUnit = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- Form open/close
  function openForm() {
    root.formOpen = true
    root.detailsKey = ""
    root.formScope = ""
    root.formUnit = ""
    root.formError = ""
    root.refreshUnitFiles()
    Qt.callLater(function() { scopeGroup.forceActiveFocus() })
  }

  function closeForm() {
    root.formOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitForm() {
    if (root.formScope === "" || root.formUnit === "") return
    if (root.addService(root.formScope, root.formUnit)) root.closeForm()
  }

  // ---- List cursor
  function rowCount() {
    return visibleRows.length
  }

  function rowAt(index) {
    if (index < 0 || index >= rowCount()) return null
    return visibleRows[index]
  }

  function selectedRow() {
    return rowAt(Math.max(0, Math.min(cursorIndex, rowCount() - 1)))
  }

  function rowItem(index) {
    return index >= 0 && index < rowsColumn.children.length ? rowsColumn.children[index] : null
  }

  function clampCursor() {
    if (cursorIndex >= rowCount()) cursorIndex = Math.max(0, rowCount() - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; clampCursor(); scrollCursorIntoView(); return }
    cursorIndex = Math.max(0, Math.min(rowCount() - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = rowItem(cursorIndex)
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function focusFilter() {
    filterField.forceActiveFocus()
    filterField.selectAll()
  }

  // ---- Public functions for `omarchy-shell shell call <id> <method> <arg>`
  // Args are JSON {"unit","scope"}, or "<scope>:<unit>", or a bare unit name
  // (user scope assumed).

  IpcHandler {
    target: root.pluginId
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function start(arg: string): string { var t = parseTarget(arg, "user"); if (t) runAction("start", t.scope, t.unit); return "ok" }
    function stop(arg: string): string { var t = parseTarget(arg, "user"); if (t) runAction("stop", t.scope, t.unit); return "ok" }
    function restart(arg: string): string { var t = parseTarget(arg, "user"); if (t) runAction("restart", t.scope, t.unit); return "ok" }
    function details(arg: string): string {
      var t = parseTarget(arg, "user")
      if (!t) return "bad-argument"
      root.open()
      root.openDetails(t.scope, t.unit)
      return "ok"
    }
    function add(arg: string): string {
      var t = parseTarget(arg, "")
      if (!t) return "bad-argument"
      return root.addService(t.scope, t.unit) ? "ok" : "error"
    }
    function remove(arg: string): string {
      var t = parseTarget(arg, "user")
      if (!t) return "bad-argument"
      root.removeService(t.scope, t.unit)
      return "ok"
    }
    function list(): string {
      var rows = []
      for (var i = 0; i < registryRows.length; i++) {
        var row = registryRows[i]
        rows.push({
          unit: row.unit,
          scope: row.scope,
          active: row.unitData.active,
          sub: row.unitData.sub,
          ram: root.memoryOf(row) !== undefined ? root.memoryOf(row) : null,
          vram: root.vramByUnit[row.unit] !== undefined ? root.vramByUnit[row.unit] : null
        })
      }
      return JSON.stringify(rows)
    }
    function polkitSync(): string { root.startPolkitSync(); return "ok" }
    function polkitRemove(): string { root.removeWhitelist(); return "ok" }
    function polkitStatus(): string {
      return JSON.stringify({ installed: root.polkitInstalled, signature: root.polkitSignature, needsSync: root.polkitNeedsSync })
    }
    function debug(): string {
      return JSON.stringify({
        build: root.buildStamp,
        busyKey: root.busyKey, busyVerb: root.busyVerb,
        actionRunning: actionProcess.running,
        polkitBusy: root.polkitBusy,
        detailsOpen: root.detailsOpen, formOpen: root.formOpen,
        opened: root.opened, cursorIndex: root.cursorIndex
      })
    }
  }

  function parseTarget(arg, defaultVerbScope) {
    var s = String(arg || "").trim()
    if (s === "") return null
    var scope = "", unit = ""
    if (s.charAt(0) === "{") {
      try {
        var o = JSON.parse(s)
        scope = String(o.scope || defaultVerbScope || "user")
        unit = String(o.unit || "")
      } catch (e) { return null }
    } else {
      var m = /^(user|system):(.+)$/.exec(s)
      if (m) { scope = m[1]; unit = m[2] }
      else { scope = defaultVerbScope || "user"; unit = s }
    }
    unit = Model.unescapeName(unit)
    if (!Model.validUnitName(unit) || !Model.validScope(scope)) return null
    return { scope: scope, unit: unit }
  }

  function start(arg) { var t = parseTarget(arg, "user"); if (t) runAction("start", t.scope, t.unit); return "ok" }
  function stop(arg) { var t = parseTarget(arg, "user"); if (t) runAction("stop", t.scope, t.unit); return "ok" }
  function restart(arg) { var t = parseTarget(arg, "user"); if (t) runAction("restart", t.scope, t.unit); return "ok" }

  function details(arg) {
    var t = parseTarget(arg, "user")
    if (!t) return "bad-argument"
    root.open()
    root.openDetails(t.scope, t.unit)
    return "ok"
  }

  function add(arg) {
    var t = parseTarget(arg, "")
    if (!t) return "bad-argument"
    return root.addService(t.scope, t.unit) ? "ok" : "error"
  }

  function remove(arg) {
    var t = parseTarget(arg, "user")
    if (!t) return "bad-argument"
    root.removeService(t.scope, t.unit)
    return "ok"
  }

  function list() {
    var rows = []
    for (var i = 0; i < registryRows.length; i++) {
      var row = registryRows[i]
      rows.push({
        unit: row.unit,
        scope: row.scope,
        active: row.unitData.active,
        sub: row.unitData.sub,
        ram: root.memoryOf(row) !== undefined ? root.memoryOf(row) : null,
        vram: root.vramByUnit[row.unit] !== undefined ? root.vramByUnit[row.unit] : null
      })
    }
    return JSON.stringify(rows)
  }

  function polkitSync() { root.startPolkitSync(); return "ok" }
  function polkitRemove() { root.removeWhitelist(); return "ok" }
  function polkitStatus() {
    return JSON.stringify({ installed: root.polkitInstalled, signature: root.polkitSignature, needsSync: root.polkitNeedsSync })
  }
  function debug() {
    return JSON.stringify({
      busyKey: root.busyKey, busyVerb: root.busyVerb,
      actionRunning: actionProcess.running,
      polkitBusy: root.polkitBusy,
      detailsOpen: root.detailsOpen, formOpen: root.formOpen,
      opened: root.opened, cursorIndex: root.cursorIndex
    })
  }
  function setup() { runSetup("install"); return "ok" }

  function runSetup(mode) {
    if (setupProcess.running) return
    setupProcess.mode = mode
    setupProcess.command = ["bash", root.setupScript, mode]
    setupProcess.running = true
  }

  function removeWhitelist() {
    askConfirm("Remove the polkit whitelist? System services will ask for your password again.", "Remove", function() {
      if (polkitRemoveProcess.running) return
      polkitRemoveProcess.command = ["pkexec", "sh", root.polkitScript, "remove"]
      polkitRemoveProcess.running = true
    })
  }

  // ---- Startup: self-setup, identity, fresh session flag
  Component.onCompleted: {
    console.warn("HubPanel: loaded build " + root.buildStamp)
    // A cancelled prompt must not nag again within the same shell session.
    if (root.stateObj.polkit.declinedSessionOnly) {
      var next = JSON.parse(JSON.stringify(root.stateObj))
      next.polkit.declinedSessionOnly = false
      root.stateObj = Model.normalizeState(next)
      root.persistState()
    }
    whoamiProcess.running = true
    runSetup("install")
  }

  // Every open repairs the launcher entry + menu row (idempotent, cheap).
  // Disable-time cleanup lives in Service.qml: the panel item is torn down
  // synchronously with the disable, before any watcher inside it can react.

  // Persisted state (registry, settings, polkit bookkeeping).
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: root.applyState("")
    onFileChanged: reload()
  }

  function applyState(raw) {
    var next = Model.normalizeState(raw)
    if (JSON.stringify(next) === JSON.stringify(root.stateObj)) return
    root.stateObj = next
  }

  // The generated rules text, written before the pkexec sync runs.
  FileView {
    id: rulesCandidateFile
    path: root.polkitCandidatePath
    atomicWrites: true
    printErrors: false
  }

  // Log colours follow the theme; re-read when details open.
  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.logPalette = Model.parseThemePalette(text())
  }

  // ---- Timers: fast while open; the details view refreshes its own unit.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: detailsTimer
    interval: 2000
    running: root.opened && root.detailsOpen
    repeat: true
    onTriggered: {
      root.nowSec = Date.now() / 1000
      root.refreshLogs()
      root.refreshStats()
      root.refreshUnitMemory()
    }
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: if (!root.actionFailed) root.actionStatus = ""
  }

  // ---- Processes
  Process {
    id: whoamiProcess
    command: ["sh", "-c", "id -un"]
    stdout: StdioCollector { id: whoamiStdout; waitForEnd: true }
    onExited: root.userName = String(whoamiStdout.text || "").trim()
  }

  Process {
    id: listUserProcess
    running: false
    command: []
    stdout: StdioCollector { id: listUserStdout; waitForEnd: true }
    stderr: StdioCollector { id: listUserStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (Model.timedOut(exitCode, exitStatus)) {
        root.loadError = "systemctl --user list-units timed out after " + Model.TIMEOUT_SEC.read + "s"
        return
      }
      if (Model.overflowed(exitCode, exitStatus)) {
        root.loadError = Model.overflowText("systemctl --user list-units")
        return
      }
      if (exitCode !== 0 || exitStatus !== 0) {
        root.loadError = Model.elide(listUserStderr.text || "systemctl --user list-units failed")
        return
      }
      var text = String(listUserStdout.text || "")
      if (root.loaded && text === root._userListText) return
      var parsed = Model.parseUnits(text)
      if (parsed === null) {
        root.loadError = "Could not parse systemctl output"
        return
      }
      root._userListText = text
      root.loadedUserUnits = parsed
      root.loaded = true
      root.loadError = ""
    }
  }

  Process {
    id: listSystemProcess
    running: false
    command: []
    stdout: StdioCollector { id: listSystemStdout; waitForEnd: true }
    stderr: StdioCollector { id: listSystemStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (Model.timedOut(exitCode, exitStatus)) {
        root.loadError = "systemctl list-units timed out after " + Model.TIMEOUT_SEC.read + "s"
        return
      }
      if (Model.overflowed(exitCode, exitStatus)) {
        root.loadError = Model.overflowText("systemctl list-units")
        return
      }
      if (exitCode !== 0 || exitStatus !== 0) {
        root.loadError = Model.elide(listSystemStderr.text || "systemctl list-units failed")
        return
      }
      var text = String(listSystemStdout.text || "")
      if (root.loaded && text === root._systemListText) return
      var parsed = Model.parseUnits(text)
      if (parsed === null) {
        root.loadError = "Could not parse systemctl output"
        return
      }
      root._systemListText = text
      root.loadedSystemUnits = parsed
      root.loaded = true
      root.loadError = ""
    }
  }

  Process {
    id: unitFilesUserProcess
    running: false
    command: []
    stdout: StdioCollector { id: unitFilesUserStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var text = String(unitFilesUserStdout.text || "")
      if (exitCode !== 0 || exitStatus !== 0 || text === root._filesUserText) return
      var states = Model.parseUnitFiles(text)
      if (states === null) return
      root._filesUserText = text
      root.userFileStates = states
    }
  }

  Process {
    id: unitFilesSystemProcess
    running: false
    command: []
    stdout: StdioCollector { id: unitFilesSystemStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var text = String(unitFilesSystemStdout.text || "")
      if (exitCode !== 0 || exitStatus !== 0 || text === root._filesSystemText) return
      var states = Model.parseUnitFiles(text)
      if (states === null) return
      root._filesSystemText = text
      root.systemFileStates = states
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var name = Model.displayName(root.busyKey.split(":").pop() || "")
      if (Model.timedOut(exitCode, exitStatus)) {
        root.actionFailed = true
        root.actionStatus = Model.actionTimeoutText(root.busyVerb, root.busyKey.split(":").pop() || "")
      } else if (Model.overflowed(exitCode, exitStatus)) {
        root.actionFailed = true
        root.actionStatus = Model.overflowText("systemctl " + root.busyVerb)
      } else if (exitCode !== 0 || exitStatus !== 0) {
        var err = String(actionStderr.text || "")
        root.actionFailed = true
        if (/interactive authentication required|access denied|authentication is required/i.test(err))
          root.actionStatus = "Not authorized — the password prompt was dismissed. Sync the polkit whitelist to make this passwordless."
        else
          root.actionStatus = Model.elide(err || (root.busyVerb + " " + name + " failed"))
      } else {
        root.actionFailed = false
        root.actionStatus = Model.doneLabel(root.busyVerb) + " " + name
        statusTimer.restart()
      }
      root.busyKey = ""
      root.busyVerb = ""
      root.refresh()
      root.refreshPolkitStatus()
      root.refocusKeyboard()
      root.afterAction()
    }
  }

  Process {
    id: enableStateProcess
    running: false
    command: []
    stdout: StdioCollector { id: enableStateStdout; waitForEnd: true }
    // is-enabled exits non-zero for "disabled"; the word on stdout is what counts.
    onExited: function(exitCode, exitStatus) {
      if (Model.timedOut(exitCode, exitStatus)) {
        root.enableError = "systemctl is-enabled timed out after " + Model.TIMEOUT_SEC.read + "s"
        return
      }
      if (Model.overflowed(exitCode, exitStatus)) {
        root.enableError = Model.overflowText("systemctl is-enabled")
        return
      }
      root.enableState = String(enableStateStdout.text || "").trim().split("\n")[0]
    }
  }

  Process {
    id: enableProcess
    property string verb: ""
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: enableStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (Model.timedOut(exitCode, exitStatus)) {
        root.enableError = Model.actionTimeoutText(enableProcess.verb, root.detailsUnit)
      } else if (Model.overflowed(exitCode, exitStatus)) {
        root.enableError = Model.overflowText("systemctl " + enableProcess.verb)
      } else if (exitCode !== 0 || exitStatus !== 0) {
        var err = String(enableStderr.text || "")
        if (/interactive authentication required|access denied|authentication is required/i.test(err))
          root.enableError = "Not authorized — the password prompt was dismissed."
        else
          root.enableError = Model.elide(err || "Could not change start at login")
      }
      root.refreshEnableState()
      root.refresh()
      root.refocusKeyboard()
    }
  }

  Process {
    id: memUserProcess
    running: false
    command: []
    stdout: StdioCollector { id: memUserStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && memUserStdout.text !== root._memUserText) {
        root._memUserText = memUserStdout.text
        root.memoryUserByUnit = Model.memoryLines(memUserStdout.text)
      }
    }
  }

  Process {
    id: memSystemProcess
    running: false
    command: []
    stdout: StdioCollector { id: memSystemStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && memSystemStdout.text !== root._memSystemText) {
        root._memSystemText = memSystemStdout.text
        root.memorySystemByUnit = Model.memoryLines(memSystemStdout.text)
      }
    }
  }

  Process {
    id: memUnitProcess
    property string unit: ""
    running: false
    command: []
    stdout: StdioCollector { id: memUnitStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var value = Model.memoryLines(memUnitStdout.text)[unit]
      if (detailsScope === "system")
        root.memorySystemByUnit = Model.withUnitValue(root.memorySystemByUnit, unit, value)
      else
        root.memoryUserByUnit = Model.withUnitValue(root.memoryUserByUnit, unit, value)
    }
  }

  Process {
    id: vramProcess
    running: false
    command: []
    stdout: StdioCollector { id: vramStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && vramStdout.text !== root._vramText) {
        root._vramText = vramStdout.text
        root.vramByUnit = Model.memoryLines(vramStdout.text)
      }
    }
  }

  Process {
    id: vramUnitProcess
    property string unit: ""
    running: false
    command: []
    stdout: StdioCollector { id: vramUnitStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0)
        root.vramByUnit = Model.withUnitValue(root.vramByUnit, unit, Model.memoryLines(vramUnitStdout.text)[unit])
    }
  }

  Process {
    id: statsProcess
    running: false
    command: []
    stdout: StdioCollector { id: statsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var blocks = Model.parseShow(statsStdout.text)
      root.stats = exitCode === 0 && blocks.length > 0 ? blocks[0] : ({})
    }
  }

  Process {
    id: logsProcess
    running: false
    command: []
    stdout: StdioCollector { id: logsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(logsStdout.text || "").replace(/\s+$/, "")
      if (text === "-- No entries --") text = ""
      if (text !== root.logsText) root.logsText = text
      root.logsLoaded = true
    }
  }

  // Probe one companion unit's active state for the chain.
  Process {
    id: companionProbeProcess
    running: false
    command: []
    stdout: StdioCollector { id: companionProbeStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var state = String(companionProbeStdout.text || "").trim().split("\n")[0]
      var head = root.chainQueue.length > 0 ? root.chainQueue[0] : null
      if (!head) return
      if (state === "active" || state === "activating") {
        // Remember it under the service's key so the next start restores it.
        // lastActionUnit is still the service here — the companion action
        // hasn't run yet.
        var key = Model.scopeKey(root.chainScope, root.lastActionUnit)
        var list = (root.stoppedCompanions[key] || []).slice()
        if (list.indexOf(head.unit) === -1) list.push(head.unit)
        root.stoppedCompanions[key] = list
        root.runAction("stop", root.chainScope, head.unit)
        if (!actionProcess.running) { root.chainQueue.shift(); chainNext() } // refused; carry on
      } else {
        // Not active: nothing to stop, resolve this step and move on. The
        // active companions shift out of the queue when their stop finishes
        // (see afterAction).
        root.chainQueue.shift()
        chainNext()
      }
    }
  }

  Process {
    id: setupProcess
    property string mode: "install"
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: polkitStatusProcess
    running: false
    command: []
    stdout: StdioCollector { id: polkitStatusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parsePolkitStatus(polkitStatusStdout.text)
      if (parsed !== null) root.polkitInstalled = parsed
      root.maybeAutoPolkit()
    }
  }

  Process {
    id: polkitSyncProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: polkitSyncStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        if (Model.timedOut(exitCode, exitStatus)) {
          root.actionFailed = true
          root.actionStatus = "Polkit whitelist sync timed out."
        } else {
          var next = JSON.parse(JSON.stringify(root.stateObj))
          next.polkit.declinedSessionOnly = true
          root.stateObj = Model.normalizeState(next)
          root.persistState()
          root.actionFailed = false
          root.actionStatus = exitCode === 127
            ? "Whitelist not updated — authentication dismissed. Actions will prompt for a password."
            : Model.elide(polkitSyncStderr.text || "Polkit whitelist sync failed.")
          statusTimer.restart()
        }
      } else {
        var now = new Date().toISOString().replace(/\.\d+Z$/, "")
        var n = JSON.parse(JSON.stringify(root.stateObj))
        n.polkit.signature = root.polkitSignature
        n.polkit.syncedAt = now
        root.stateObj = Model.normalizeState(n)
        root.persistState()
        root.actionStatus = "Polkit whitelist updated."
        root.actionFailed = false
        statusTimer.restart()
      }
      root.refreshPolkitStatus()
      root.refocusKeyboard()
    }
  }

  Process {
    id: polkitRemoveProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: polkitRemoveStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        root.actionFailed = true
        root.actionStatus = Model.elide(polkitRemoveStderr.text || "Could not remove the whitelist.")
        statusTimer.restart()
      } else {
        root.polkitRemoved()
      }
      root.refreshPolkitStatus()
      root.refocusKeyboard()
    }
  }

  // Last raw outputs, to skip re-publishing identical results.
  property string _userListText: ""
  property string _systemListText: ""
  property string _filesUserText: ""
  property string _filesSystemText: ""
  property string _memUserText: ""
  property string _memSystemText: ""
  property string _vramText: ""

  // ------------------------------------------------------------ window

  PanelWindow {
    id: panelWindow
    visible: root.opened
    implicitWidth: root.detailsOpen ? Style.space(660) : Style.space(460)
    implicitHeight: Style.space(680)
    color: "transparent"
    WlrLayershell.namespace: "geryruslandi-services-hub"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    BorderSurface {
      id: card
      anchors.fill: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: function() {} }

      // Keyboard owner for the whole card. Text fields and the dropdown
      // take focus when active and simply don't route here.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.confirmOpen) {
            confirmDialog.handleKey(event)
            event.accepted = true
            return
          }

          if (root.detailsOpen) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.text === "q") {
              root.closeDetails(); event.accepted = true
            } else if (event.text === "e") {
              root.setEnabled(!Model.isEnabledState(root.enableState)); event.accepted = true
            } else if (event.text === "r") {
              root.restartRow(root.detailsData ? { scope: root.detailsScope, unit: root.detailsUnit, unitData: root.detailsData } : null); event.accepted = true
            } else if (event.text === "f") {
              root.followLogs(); event.accepted = true
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              logsFlick.scrollBy(Style.space(40)); event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              logsFlick.scrollBy(-Style.space(40)); event.accepted = true
            }
            return
          }

          if (root.formOpen) {
            if (formDropdown.popupOpen) return // the dropdown owns the keys
            if (event.key === Qt.Key_Escape) {
              root.closeForm(); event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.submitForm(); event.accepted = true
            }
            return
          }

          // List mode.
          if (event.key === Qt.Key_Escape) {
            if (root.query !== "") { root.query = ""; event.accepted = true }
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            root.moveCursor(-1); event.accepted = true
          } else if (event.key === Qt.Key_Down || event.text === "j") {
            root.moveCursor(1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) {
            if (root.cursorActive) root.toggleRow(root.selectedRow())
            event.accepted = true
          } else if (event.text === "d" || event.text === "i") {
            var row = root.selectedRow()
            if (row) root.openDetails(row.scope, row.unit)
            event.accepted = true
          } else if (event.text === "r") {
            if (root.cursorActive) root.restartRow(root.selectedRow())
            event.accepted = true
          } else if (event.text === "a") {
            root.openForm(); event.accepted = true
          } else if (event.text === "/") {
            root.focusFilter(); event.accepted = true
          } else if (event.text === "R") {
            root.refresh(); event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (root.cursorActive) root.requestRemove(root.selectedRow())
            event.accepted = true
          }
        }

        // ---- List view
        Flickable {
          id: panelFlick
          visible: !root.detailsOpen && !root.formOpen
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: panelFlick.width
            spacing: Style.space(12)

            // Header: title + counts on the left, add + refresh on the right.
            Item {
              width: parent.width
              implicitHeight: Math.max(hero.implicitHeight, headerControls.implicitHeight)

              PanelHero {
                id: hero
                width: parent.width - headerControls.width - Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                title: "Services hub"
                meta: {
                  if (root.loadError !== "") return "Unavailable"
                  if (!root.loaded) return "Loading…"
                  if (root.registry.length === 0) return "Nothing registered yet"
                  var parts = [root.runningCount + " running"]
                  if (root.failedCount > 0) parts.push(root.failedCount + " failed")
                  parts.push(root.registry.length + " registered")
                  return parts.join(" · ")
                }
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconComponent: Component {
                  Text {
                    text: "󰒋"
                    color: root.failedCount > 0 ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                  }
                }
              }

              Row {
                id: headerControls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰐭"
                  tooltipText: "Add a service (a)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openForm()
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰑐"
                  tooltipText: "Refresh (R)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.refresh()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.actionStatus !== "" || root.loadError !== ""
              width: parent.width
              text: root.loadError !== "" ? root.loadError : root.actionStatus
              color: root.loadError !== "" || root.actionFailed ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: filterField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Filter registered services  (/)"
              text: root.query
              onTextChanged: {
                root.query = text
                root.cursorIndex = 0
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (text !== "") text = ""
                  else root.close()
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  keyCatcher.forceActiveFocus()
                  root.cursorActive = true
                  root.cursorIndex = 0
                  event.accepted = true
                }
              }
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            Text {
              visible: root.loaded && root.visibleRows.length === 0
              width: parent.width
              text: root.registry.length === 0
                ? "No services registered yet. Add one with 󰐭 or press a."
                : root.query !== "" ? "No services match." : "Nothing to show."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            // Registered rows.
            Column {
              id: rowsColumn
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.visibleRows
                ServiceRow {
                  required property var modelData
                  required property int index
                  width: rowsColumn.width
                  rowData: modelData
                  rowIndex: index
                }
              }
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            // Polkit footer.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: {
                  if (root.polkitBusy) return "Polkit whitelist: working…"
                  if (root.polkitNeedsSync) {
                    if (root.registry.length === 0 || root.polkitSignature === "")
                      return "Polkit whitelist: not needed yet"
                    return root.polkitInstalled && root.polkitInstalled.present
                      ? "Polkit whitelist: stale — registry changed, sync to update"
                      : "Polkit whitelist: not set up — sync to control system services without a password"
                  }
                  if (root.polkitInstalled && root.polkitInstalled.present || root.polkitSignature === root.stateObj.polkit.signature)
                    return "Polkit whitelist: " + root.polkitUnits.length + " units (services + sockets/timers) · synced " + (root.stateObj.polkit.syncedAt || "")
                  return "Polkit whitelist: not set up"
                }
                color: root.polkitNeedsSync && root.polkitSignature !== "" ? root.dim : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              RowIconButton {
                glyph: "󰦎"
                tooltipText: "Sync polkit whitelist (one password prompt)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.startPolkitSync()
              }

              RowIconButton {
                glyph: "󰆴"
                tooltipText: "Remove polkit whitelist"
                foreground: root.dim
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.removeWhitelist()
              }
            }
          }
        }

        // ---- Details view
        ColumnLayout {
          id: detailsContent
          visible: root.detailsOpen
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.space(12)

          // Header: back, name + description, restart.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            RowIconButton {
              glyph: "󰁍"
              tooltipText: "Back (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignTop
              onClicked: root.closeDetails()
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: Model.displayName(root.detailsUnit)
                  color: Model.isFailed(root.detailsData) ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                }

                ScopeChip {
                  scope: root.detailsScope
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: text !== ""
                text: Model.descriptionOf(root.detailsData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }

            RowIconButton {
              glyph: "󰑖"
              tooltipText: "Restart service (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.busyKey === "" && Model.isStartable(root.detailsData)
              Layout.alignment: Qt.AlignTop
              onClicked: root.restartRow({ scope: root.detailsScope, unit: root.detailsUnit, unitData: root.detailsData })
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: root.busyKey === root.detailsKey && root.busyKey !== ""
              ? Model.busyLabel(root.busyVerb)
              : root.actionStatus
            color: root.actionFailed && root.busyKey === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Resource figures. PID and uptime only live here.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            StatCell {
              label: "STATUS"
              value: root.detailsData ? (root.detailsData.sub || root.detailsData.active) : "—"
              valueColor: Model.isFailed(root.detailsData) ? root.urgent : root.foreground
            }
            StatCell {
              label: "PID"
              value: root.detailsRunning && Model.numberOrNull(root.stats.MainPID) > 0 ? String(root.stats.MainPID) : "—"
            }
            StatCell {
              label: "UPTIME"
              value: root.detailsRunning && root.activeSince ? Model.formatDuration(root.nowSec - root.activeSince) : "—"
            }
            StatCell {
              label: "MEMORY"
              value: root.detailsRunning && root.memoryOf({ scope: root.detailsScope, unit: root.detailsUnit }) !== undefined
                ? Model.formatBytes(root.memoryOf({ scope: root.detailsScope, unit: root.detailsUnit })) : "—"
            }
            StatCell {
              label: "VRAM"
              value: root.detailsRunning && root.vramByUnit[root.detailsUnit] !== undefined
                ? Model.formatBytes(root.vramByUnit[root.detailsUnit]) : "—"
            }
            StatCell {
              label: "CPU"
              value: Model.formatCpu(Model.numberOrNull(root.stats.CPUUsageNSec))
            }
            StatCell {
              label: "TASKS"
              value: root.detailsRunning && Model.numberOrNull(root.stats.TasksCurrent) !== null ? String(root.stats.TasksCurrent) : "—"
              detail: Model.numberOrNull(root.stats.NRestarts) > 0 ? root.stats.NRestarts + " restarts" : ""
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Start at login (the enable config).
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Start at login"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.enableError !== "" ? root.enableError : Model.enableStateHint(root.enableState)
                color: root.enableError !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            ToggleSwitch {
              id: enableSwitch
              Layout.alignment: Qt.AlignVCenter
              enabled: Model.canToggleEnable(root.enableState)
              opacity: enabled ? 1.0 : 0.4
              checked: Model.isEnabledState(root.enableState)
              busy: enableProcess.running
              cursorRing: false
              foreground: root.foreground
              onToggled: root.setEnabled(!checked)
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // Logs.
          RowLayout {
            Layout.fillWidth: true

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "LOGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowIconButton {
              glyph: "󰆍"
              tooltipText: "Follow in terminal (f)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.followLogs()
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

            Flickable {
              id: logsFlick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              contentWidth: width
              contentHeight: logsEdit.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              // Stay pinned to the newest line unless the user scrolled up.
              property bool pinned: true
              readonly property real bottomY: Math.max(0, contentHeight - height)
              function scrollBy(dy) {
                contentY = Math.max(0, Math.min(bottomY, contentY + dy))
                pinned = contentY >= bottomY - Style.space(8)
              }
              // Deferred: the wrapped text settles its height after the
              // change that triggered this, so scroll once layout is done.
              function pinToEnd() {
                if (!pinned) return
                Qt.callLater(function() {
                  logsFlick.contentY = Math.max(0, logsFlick.contentHeight - logsFlick.height)
                })
              }
              onMovementEnded: pinned = contentY >= bottomY - Style.space(8)
              onContentHeightChanged: pinToEnd()
              onHeightChanged: pinToEnd()

              TextEdit {
                id: logsEdit
                width: logsFlick.width
                readOnly: true
                selectByMouse: true
                // Rich text built by Model.logsHtml: severity colours, dimmed
                // headers, the service's own ANSI colours. Everything from
                // the journal is HTML-escaped there.
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.WrapAnywhere
                text: !root.logsLoaded
                  ? Model.plainHtml("Loading…", String(root.dim))
                  : (root.logsText !== ""
                    ? Model.logsHtml(root.logsText, root.logColors)
                    : Model.plainHtml("No log entries.", String(root.dim)))
                color: root.foreground
                selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- Add-service form view
        ColumnLayout {
          id: formContent
          visible: root.formOpen
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.space(12)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            RowIconButton {
              glyph: "󰁍"
              tooltipText: "Back (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignTop
              onClicked: root.closeForm()
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Add a service"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "Pick the scope first — it decides which services the list shows."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Step 1: scope.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "SCOPE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            ButtonGroup {
              id: scopeGroup
              Layout.fillWidth: true
              options: [
                { value: "user", label: "User service" },
                { value: "system", label: "System service" }
              ]
              value: root.formScope
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                root.formScope = v
                root.formUnit = ""
                root.formError = ""
              }
            }
          }

          // Step 2: the unit dropdown for the chosen scope.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "SERVICE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            SearchableDropdown {
              id: formDropdown
              Layout.fillWidth: true
              enabled: root.formScope !== ""
              options: root.formOptions
              value: root.formUnit
              label: ""
              showLabel: false
              placeholderText: root.formScope === "" ? "Choose a scope first" : "Search services…"
              emptyText: root.formScope === "" ? "—" : "No matches"
              foreground: root.foreground
              background: root.background
              popupBorder: root.border
              accent: root.accent
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === -1
              onChanged: function(v) {
                root.formUnit = v
                root.formError = ""
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.formScope !== "" && root.formOptions.length === 0 && (root._filesUserText === "" || root._filesSystemText === "")
              text: "Loading services…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: root.formError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Item { Layout.fillHeight: true; Layout.fillWidth: true }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Item { Layout.fillWidth: true }

            Button {
              text: "Cancel"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: root.closeForm()
            }

            Button {
              text: "Add service"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.formScope !== "" && root.formUnit !== ""
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.submitForm()
            }
          }
        }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.confirmOpen
          z: 10
          message: root.confirmMessage
          confirmText: root.confirmLabel
          background: root.background
          foreground: root.foreground
          fontFamily: root.fontFamily
          onConfirmed: {
            root.confirmOpen = false
            var action = root.pendingConfirm
            root.pendingConfirm = null
            if (action) action()
          }
          onCanceled: {
            root.confirmOpen = false
            root.pendingConfirm = null
          }
        }
      }
    }
  }

  // ---- Components

  // One registered service row: status dot, name, description, RAM/VRAM,
  // scope chip, details, remove, and the start/stop switch.
  component ServiceRow: CursorSurface {
    id: row
    property var rowData: null
    property int rowIndex: 0
    readonly property var unitData: rowData ? rowData.unitData : null
    readonly property string scope: rowData ? rowData.scope : "user"
    readonly property string unitName: rowData ? rowData.unit : ""
    readonly property string rowKey: Model.scopeKey(scope, unitName)
    readonly property bool present: Model.isStartable(unitData)
    readonly property bool running: Model.isRunning(unitData)
    readonly property bool failed: Model.isFailed(unitData)
    readonly property bool busy: root.busyKey !== "" && root.busyKey === rowKey
    readonly property bool anyBusy: root.busyKey !== ""
    readonly property var ram: root.memoryOf({ scope: row.scope, unit: row.unitName })
    readonly property var vram: root.vramByUnit[unitName]

    hasCursor: rowMouse.pressed || (root.cursorActive && root.cursorIndex === rowIndex)
    foreground: root.foreground
    z: rowMouse.pressed ? 10 : 0
    implicitHeight: Math.max(content.implicitHeight, powerSwitch.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onContainsMouseChanged: if (containsMouse) root.setCursor(row.rowIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.refresh()
        else if (root.cursorActive && root.cursorIndex === row.rowIndex) root.openDetails(row.scope, row.unitName)
        else root.setCursor(row.rowIndex)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(8)
        implicitHeight: Style.space(8)
        radius: width / 2
        color: row.failed ? root.urgent : (row.running ? root.foreground : "transparent")
        border.width: row.running || row.failed ? 0 : 1
        border.color: root.dim
        opacity: row.busy || Model.isTransitioning(row.unitData) ? 0.4 : 1.0

        SequentialAnimation on opacity {
          running: row.busy
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.3; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: content
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.displayName(row.unitName)
          color: row.failed ? root.urgent : (row.running ? root.foreground : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: Model.descriptionOf(row.unitData)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ScopeChip {
        scope: row.scope
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
      }

      // RAM, with GPU memory underneath when the service holds any. One
      // hover area over both figures; the tooltip names them.
      Item {
        visible: row.running && (row.ram !== undefined || row.vram !== undefined)
        Layout.alignment: Qt.AlignVCenter
        Layout.minimumWidth: Style.space(40)
        implicitWidth: figures.implicitWidth
        implicitHeight: figures.implicitHeight

        ColumnLayout {
          id: figures
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          MemoryFigure {
            Layout.alignment: Qt.AlignRight
            visible: row.ram !== undefined
            text: Model.formatBytes(row.ram)
          }

          MemoryFigure {
            Layout.alignment: Qt.AlignRight
            visible: row.vram !== undefined
            text: Model.formatBytes(row.vram)
          }
        }

        MouseArea {
          id: figuresMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onContainsMouseChanged: if (containsMouse) root.setCursor(row.rowIndex)
        }

        PanelToolTip {
          visible: figuresMouse.containsMouse
          text: Model.memoryTooltip(row.ram, row.vram)
          fontFamily: root.fontFamily
        }
      }

      RowIconButton {
        glyph: "󰋽"
        tooltipText: "Details (d)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onClicked: root.openDetails(row.scope, row.unitName)
      }

      RowIconButton {
        glyph: "󰆴"
        tooltipText: "Remove from the hub (Delete)"
        foreground: root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onClicked: root.requestRemove({ scope: row.scope, unit: row.unitName })
      }

      ToggleSwitch {
        id: powerSwitch
        Layout.alignment: Qt.AlignVCenter
        enabled: row.present
        opacity: row.present ? 1.0 : 0.4
        checked: row.busy ? (root.busyVerb !== "stop") : row.running
        busy: row.anyBusy
        cursorRing: false
        foreground: root.foreground
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onToggled: root.toggleRow({ scope: row.scope, unit: row.unitName, unitData: row.unitData })
      }
    }
  }

  // Small USER/SYSTEM tag.
  component ScopeChip: Rectangle {
    property string scope: "user"
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    Layout.alignment: Qt.AlignVCenter
    implicitWidth: chipText.implicitWidth + Style.space(8)
    implicitHeight: chipText.implicitHeight + Style.space(4)
    radius: height / 2
    color: "transparent"
    border.width: 1
    border.color: Qt.darker(foreground, 1.4)

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.scope === "system" ? "SYS" : "USER"
      color: Qt.darker(parent.foreground, 1.3)
      font.family: parent.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  // A small dim figure on a row.
  component MemoryFigure: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // One labelled figure in the details stats strip.
  component StatCell: ColumnLayout {
    property string label: ""
    property string value: ""
    property string detail: ""
    property color valueColor: root.foreground
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    Layout.alignment: Qt.AlignTop
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: text !== ""
      text: parent.detail
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Nerd Font icons sit high in their line box, so centering the Text item
  // leaves the glyph above its neighbours. This centers the painted bounds.
  component CenteredGlyph: Item {
    id: cg
    property string text: ""
    property color color: root.foreground
    property real fontSize: Style.font.icon

    TextMetrics {
      id: cgMetrics
      font: cgText.font
      text: cg.text
    }

    Text {
      id: cgText
      textFormat: Text.PlainText
      text: cg.text
      color: cg.color
      font.family: root.fontFamily
      font.pixelSize: cg.fontSize
      x: Math.round((cg.width - cgMetrics.tightBoundingRect.width) / 2 - cgMetrics.tightBoundingRect.x)
      y: Math.round((cg.height - cgMetrics.tightBoundingRect.height) / 2 - cgText.baselineOffset - cgMetrics.tightBoundingRect.y)
    }
  }

  // PanelActionButton with its icon drawn by CenteredGlyph.
  component RowIconButton: PanelActionButton {
    id: rib
    property string glyph: ""
    iconText: ""

    CenteredGlyph {
      anchors.fill: parent
      text: rib.glyph
      fontSize: rib.fontSize
      color: rib.enabled ? (rib._hot ? rib.hoverColor : rib.foreground) : Qt.darker(rib.foreground, 2.0)
    }
  }
}
