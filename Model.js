.pragma library

// Pure helpers for the Services Hub panel: parse `systemctl … -o json`,
// manage the service registry, generate the polkit whitelist rules.
// Ported from the MIT-licensed gabepsilva/omarchy-user-services (Model.js)
// and extended for the hub: service registry instead of favorites, user +
// system scopes, and polkit rule generation. Kept free of QML so it can be
// exercised from node.

// Lists coming from the QML engine (e.g. JSON state) are sequence
// wrappers: `instanceof Array` is true but Array.isArray is false. Plain
// arrays from another JS realm (tests) are the reverse. Accept both.
function isList(value) {
  return value instanceof Array || Array.isArray(value)
}

function parseUnits(text) {
  var raw
  try {
    raw = JSON.parse(String(text || "[]"))
  } catch (e) {
    return null
  }
  if (!isList(raw)) return null

  var units = []
  for (var i = 0; i < raw.length; i++) {
    var u = raw[i] || {}
    var name = String(u.unit || "")
    if (name === "") continue
    units.push({
      unit: name,
      load: String(u.load || ""),
      active: String(u.active || ""),
      sub: String(u.sub || ""),
      description: String(u.description || "")
    })
  }
  return units
}

// systemd escapes unit names (`\x2d` for "-"); show the readable form.
function unescapeName(name) {
  return String(name || "").replace(/\\x([0-9a-fA-F]{2})/g, function(_, hex) {
    return String.fromCharCode(parseInt(hex, 16))
  })
}

function displayName(unit) {
  return unescapeName(unit).replace(/\.service$/, "")
}

function isRunning(u) {
  return !!u && (u.active === "active" || u.active === "activating" || u.active === "reloading")
}

function isTransitioning(u) {
  return !!u && (u.active === "activating" || u.active === "deactivating" || u.active === "reloading")
}

function isFailed(u) {
  return !!u && u.active === "failed"
}

function isAutostart(u) {
  return /^app-.*@autostart\.service$/.test(u.unit)
}

// Transient D-Bus activated units and template-less leftovers are not
// something a person starts or stops by hand.
function isTransient(u) {
  return /^dbus-:/.test(u.unit)
}

// A unit systemctl can start: loaded, or installed but unloaded right now
// (`start` loads it on demand).
function isStartable(u) {
  return !!u && (u.load === "loaded" || u.load === "not-loaded")
}

// `systemctl [--user] list-unit-files -o json`: unit file name -> state
// ("enabled", "disabled", "static", …). Null on junk.
function parseUnitFiles(text) {
  var raw
  try {
    raw = JSON.parse(String(text || "[]"))
  } catch (e) {
    return null
  }
  if (!isList(raw)) return null
  var states = {}
  for (var i = 0; i < raw.length; i++) {
    var f = raw[i] || {}
    var name = String(f.unit_file || "")
    if (name !== "") states[name] = String(f.state || "")
  }
  return states
}

// list-units only returns what systemd has loaded, and a stopped, disabled
// service nothing refers to gets unloaded: stop one and it would drop off
// the list, with no way to start it again. Installed services that can be
// enabled or disabled are added back as stopped rows. Templates
// ("foo@.service") need an instance name, so they are left out.
function withInstalledUnits(units, fileStates) {
  var out = (units || []).slice()
  var seen = unitMap(out)
  for (var name in fileStates || {}) {
    var state = fileStates[name]
    if (state !== "enabled" && state !== "disabled") continue
    if (seen[name] || name.indexOf("@.") !== -1) continue
    out.push({ unit: name, load: "not-loaded", active: "inactive", sub: "dead", description: "" })
  }
  return out
}

function filterUnits(units, options) {
  var opts = options || {}
  var query = String(opts.query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < (units || []).length; i++) {
    var u = units[i]
    if (!isStartable(u)) continue
    if (isTransient(u)) continue
    if (opts.hideAutostart && isAutostart(u)) continue
    if (!opts.showInactive && !isRunning(u) && !isFailed(u)) continue
    if (query !== "") {
      var hay = (displayName(u.unit) + " " + u.description).toLowerCase()
      if (hay.indexOf(query) === -1) continue
    }
    out.push(u)
  }
  out.sort(function(a, b) {
    var ra = rank(a), rb = rank(b)
    if (ra !== rb) return ra - rb
    return displayName(a.unit).localeCompare(displayName(b.unit))
  })
  return out
}

// Failed first (they want attention), then running, then stopped.
function rank(u) {
  if (isFailed(u)) return 0
  if (isRunning(u)) return 1
  return 2
}

function countRunning(units) {
  var n = 0
  for (var i = 0; i < (units || []).length; i++) if (isRunning(units[i])) n++
  return n
}

function countFailed(units) {
  var n = 0
  for (var i = 0; i < (units || []).length; i++) if (isFailed(units[i])) n++
  return n
}

// ---- Deadlines
//
// Every command runs under coreutils `timeout`, so a hung systemctl (say, a
// stuck bus) can't leave a Process running forever; each refresh skips
// while its previous run is still going, so one hang would freeze the list.
// TERM at the deadline, KILL two seconds later if that wasn't enough.
// System-scope actions go through pkexec, which waits for the polkit
// password dialog: they get a longer deadline than plain user actions.
var TIMEOUT_SEC = { read: 10, action: 30, systemAction: 120 }

function timed(seconds, argv) {
  return ["timeout", "--kill-after=2", seconds + "s"].concat(argv)
}

// timeout exits 124 after TERM worked. When it has to KILL, it re-raises
// KILL on itself: 137 from a shell, a crash exit (status 1) with code 9
// from Quickshell.
function timedOut(exitCode, exitStatus) {
  return exitCode === 124 || exitCode === 137 || (exitStatus === 1 && exitCode === 9)
}

// ---- Output caps
//
// A deadline bounds how long a command runs, not how much it prints, and
// the panel collects output whole. So every command also runs under
// capped.sh, which cuts stdout and stderr at OUTPUT_CAP_BYTES before they
// reach the shell. Output over the cap is dropped, not passed on cut, and
// exits OVERFLOW_EXIT. 1 MiB is far past a real inventory.
var OUTPUT_CAP_BYTES = 1048576
var OVERFLOW_EXIT = 90

// argv under both limits: timeout outside, so its kill reaches the whole
// capped pipeline.
function bounded(seconds, cappedScript, argv) {
  return timed(seconds, ["bash", cappedScript, String(OUTPUT_CAP_BYTES)].concat(argv))
}

function overflowed(exitCode, exitStatus) {
  return exitStatus === 0 && exitCode === OVERFLOW_EXIT
}

function overflowText(what) {
  return what + " printed over " + (OUTPUT_CAP_BYTES / 1048576) + " MiB; not shown"
}

// Killing the systemctl client doesn't cancel the job it queued, so a slow
// stop (TimeoutStopSec defaults to 90s) carries on without us.
function actionTimeoutText(verb, unit) {
  var label = { start: "Start", stop: "Stop", restart: "Restart", enable: "Enable", disable: "Disable" }[verb] || verb
  return label + " " + displayName(unit) + " is taking over " + TIMEOUT_SEC.action + "s; systemd is still working on it"
}

// Status line wording for an action in flight and once it finished.
function busyLabel(verb) {
  return { start: "Starting…", stop: "Stopping…", restart: "Restarting…" }[verb] || "Working…"
}

function doneLabel(verb) {
  return { start: "Started", stop: "Stopped", restart: "Restarted", enable: "Enabled", disable: "Disabled" }[verb] || "Done"
}

function elide(text, max) {
  var s = String(text || "").replace(/\s+/g, " ").trim()
  var limit = max || 160
  return s.length > limit ? s.slice(0, limit - 1) + "…" : s
}

// ---- The service registry: entries of { unit, scope }, stored in the
// plugin's state file. It replaces the reference widget's favorites.

// systemd unit names: ASCII letters, digits and . _ @ - +. Only plain
// (non-template) .service units are registrable — templates ("foo@.service")
// need an instance name before systemd can start them.
var UNIT_NAME_RE = /^[A-Za-z0-9@._+-]+\.service$/

function validUnitName(unit) {
  var name = String(unit || "")
  return UNIT_NAME_RE.test(name) && name.indexOf("@.") === -1
}

function validScope(scope) {
  return scope === "user" || scope === "system"
}

// "<scope>:<unit>" — the key everywhere (UI, actions, IPC), so the same
// unit name registered in both scopes stays two independent rows.
function scopeKey(scope, unit) {
  return scope + ":" + unit
}

function normalizeRegistry(value) {
  var out = []
  if (!isList(value)) return out
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    var entry = value[i] || {}
    var unit = String(entry.unit || "")
    var scope = String(entry.scope || "user")
    if (!validUnitName(unit) || !validScope(scope)) continue
    var key = scopeKey(scope, unit)
    if (seen[key]) continue
    seen[key] = 1
    out.push({ unit: unit, scope: scope })
  }
  return out
}

function registryHas(registry, scope, unit) {
  var key = scopeKey(scope, unit)
  for (var i = 0; i < (registry || []).length; i++)
    if (scopeKey(registry[i].scope, registry[i].unit) === key) return true
  return false
}

// Add an entry. Returns { list, error }; error is "" on success. The list
// is a new array either way, so callers can assign it straight to state.
function addToRegistry(registry, scope, unit) {
  if (!validScope(scope)) return { list: normalizeRegistry(registry), error: "Pick user or system first." }
  if (!validUnitName(unit)) return { list: normalizeRegistry(registry), error: "Not a service unit name." }
  if (registryHas(registry, scope, unit)) return { list: normalizeRegistry(registry), error: displayName(unit) + " is already registered (" + scope + ")." }
  var list = normalizeRegistry(registry)
  list.push({ unit: unit, scope: scope })
  return { list: list, error: "" }
}

// Remove by scope key. Missing entries are not an error.
function removeFromRegistry(registry, scope, unit) {
  var key = scopeKey(scope, unit)
  var out = []
  for (var i = 0; i < (registry || []).length; i++)
    if (scopeKey(registry[i].scope, registry[i].unit) !== key) out.push(registry[i])
  return out
}

// Unit names of one scope, in registry order.
function registryUnitNames(registry, scope) {
  var out = []
  for (var i = 0; i < (registry || []).length; i++)
    if (!scope || registry[i].scope === scope) out.push(registry[i].unit)
  return out
}

// The polkit whitelist covers exactly the registered system units.
function systemUnitNames(registry) {
  return registryUnitNames(registry, "system")
}

// The socket/timer companions that decide whether a stopped service STAYS
// stopped: while a service's socket unit is active, anything opening it
// starts the service again (docker.service/docker.socket is the classic
// case). Only .service units have companions.
function companionUnits(unit) {
  var name = String(unit || "")
  if (!/\.service$/.test(name)) return []
  var base = name.slice(0, name.length - ".service".length)
  return [base + ".socket", base + ".timer"]
}

function dedupeUnits(names) {
  var out = []
  for (var i = 0; i < (names || []).length; i++)
    if (out.indexOf(names[i]) === -1) out.push(names[i])
  return out
}

// Everything the hub manages for a scope: registered services plus their
// socket/timer companions (companion units that don't exist are harmless
// everywhere they end up used).
function managedUnits(registry, scope) {
  var names = registryUnitNames(registry, scope)
  var out = names.slice()
  for (var i = 0; i < names.length; i++)
    out = out.concat(companionUnits(names[i]))
  return dedupeUnits(out)
}

function sameList(a, b) {
  if ((a || []).length !== (b || []).length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function unitMap(units) {
  var map = {}
  for (var i = 0; i < (units || []).length; i++) map[units[i].unit] = units[i]
  return map
}

// A registered unit that is gone (uninstalled) still gets a row so it can
// be started again after reinstall or removed. Installed but unloaded
// units are in the map already (see withInstalledUnits) and stay startable.
function registryUnit(map, name) {
  return map[name] || { unit: name, load: "not-found", active: "inactive", sub: "not loaded", description: "" }
}

// Rows for the panel: one per registry entry, sorted failed first, then
// running, then stopped, then by name.
function registeredRows(registry, userMap, systemMap) {
  var out = []
  for (var i = 0; i < (registry || []).length; i++) {
    var entry = registry[i]
    var map = entry.scope === "system" ? (systemMap || {}) : (userMap || {})
    out.push({ scope: entry.scope, unit: entry.unit, unitData: registryUnit(map, entry.unit) })
  }
  out.sort(function(a, b) {
    var ra = rank(a.unitData), rb = rank(b.unitData)
    if (ra !== rb) return ra - rb
    return displayName(a.unit).localeCompare(displayName(b.unit))
  })
  return out
}

// Filter the registered rows: query over name/description/scope, plus the
// show-inactive and hide-autostart settings. Unlike filterUnits this keeps
// not-found rows (they must stay removable) and transient rows are
// irrelevant here — the registry only holds what the user picked.
function filterRegistered(rows, options) {
  var opts = options || {}
  var query = String(opts.query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    var row = rows[i]
    if (opts.hideAutostart && isAutostart(row.unitData)) continue
    if (!opts.showInactive && !isRunning(row.unitData) && !isFailed(row.unitData)) continue
    if (query !== "") {
      var hay = (displayName(row.unit) + " " + row.scope + " " + descriptionOf(row.unitData)).toLowerCase()
      if (hay.indexOf(query) === -1) continue
    }
    out.push(row)
  }
  return out
}

// Options for the add-service form dropdown, from one scope's unit-file
// states: installed services with their enable state as the label suffix.
// Templates ("foo@.service") and already-registered units are left out.
function dropdownItems(fileStates, registry, scope) {
  var out = []
  for (var name in fileStates || {}) {
    if (name.indexOf("@.") !== -1) continue
    if (!validUnitName(name)) continue
    if (registryHas(registry, scope, name)) continue
    out.push({ value: name, label: displayName(name) + " — " + fileStates[name] })
  }
  out.sort(function(a, b) { return a.label.localeCompare(b.label) })
  return out
}

// ---- Details

function descriptionOf(u) {
  if (!u) return ""
  var d = String(u.description || "")
  return d === u.unit ? "" : d
}

// `systemctl is-enabled` words. Only enabled/disabled are something a
// person flips; the rest are explained instead.
function isEnabledState(state) {
  return state === "enabled" || state === "enabled-runtime" || state === "linked" || state === "alias"
}

function canToggleEnable(state) {
  return state === "enabled" || state === "disabled"
}

function enableStateHint(state) {
  switch (state) {
  case "": return "Checking…"
  case "enabled": return "Starts automatically when you log in"
  case "disabled": return "Only runs when started by hand or by another unit"
  case "enabled-runtime": return "Enabled until next reboot"
  case "static": return "Static: started by other units, has no install section"
  case "indirect": return "Indirect: enabled through another unit"
  case "generated": return "Generated: managed automatically (e.g. XDG autostart)"
  case "transient": return "Transient: created at runtime"
  case "masked": return "Masked: cannot be started"
  case "alias": return "Alias of another unit"
  case "linked": return "Linked from outside the unit path"
  case "not-found": return "Unit file not found"
  default: return state
  }
}

// Stopping or restarting these breaks the desktop session until they are
// restarted — ask for confirmation first. Extended to system scope from
// the reference widget's user-scope warning.
var CRITICAL_UNITS = [
  "dbus-broker.service", "dbus.service",
  "pipewire.service", "pipewire-pulse.service", "wireplumber.service",
  "systemd-udevd.service", "systemd-journald.service", "systemd-logind.service",
  "NetworkManager.service", "iwd.service", "wpa_supplicant.service"
]

function isCritical(unit) {
  return CRITICAL_UNITS.indexOf(String(unit || "")) !== -1
}

// ---- Resource figures from `systemctl show`

// `systemctl show` prints KEY=value lines, one blank-line-separated block
// per unit. Returns an array of { Key: "value" } objects.
function parseShow(text) {
  var blocks = []
  var current = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") { current = null; continue }
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    if (!current) { current = {}; blocks.push(current) }
    current[line.slice(0, eq)] = line.slice(eq + 1)
  }
  return blocks
}

// Unset figures come back as "[not set]" or the max-uint64 sentinel.
function numberOrNull(value) {
  var s = String(value === undefined ? "" : value)
  if (s === "" || s === "[not set]" || s === "infinity" || s === "18446744073709551615") return null
  var n = Number(s)
  return isFinite(n) ? n : null
}

// memory.sh output: one "<unit>=<bytes>" line per service.
function memoryLines(text) {
  var map = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].lastIndexOf("=")
    if (eq <= 0) continue
    var bytes = Number(lines[i].slice(eq + 1))
    if (isFinite(bytes) && bytes > 0) map[lines[i].slice(0, eq)] = bytes
  }
  return map
}

function formatBytes(bytes) {
  if (bytes === null || bytes === undefined || !(bytes >= 0)) return "—"
  var units = ["B", "K", "M", "G", "T"]
  var v = bytes, u = 0
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (v >= 10 || u === 0 ? Math.round(v) : Math.round(v * 10) / 10) + units[u]
}

function formatDuration(seconds) {
  if (seconds === null || seconds === undefined || !(seconds >= 0)) return "—"
  var s = Math.floor(seconds)
  var d = Math.floor(s / 86400); s -= d * 86400
  var h = Math.floor(s / 3600); s -= h * 3600
  var m = Math.floor(s / 60); s -= m * 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m " + s + "s"
  return s + "s"
}

// `--timestamp=unix` gives "@<seconds>".
function unixTimestamp(value) {
  var m = /^@(\d+)/.exec(String(value || ""))
  return m ? Number(m[1]) : null
}

function formatCpu(nsec) {
  if (nsec === null) return "—"
  return formatDuration(nsec / 1e9)
}

// Row memory tooltip; labels padded so the figures line up in a
// monospace face.
function memoryTooltip(ram, vram) {
  var lines = []
  if (ram !== undefined) lines.push("RAM:  " + formatBytes(ram))
  if (vram !== undefined) lines.push("VRAM: " + formatBytes(vram))
  return lines.join("\n")
}

// A copy of `map` with `unit` set to `value` (or removed when undefined).
// Returns `map` itself when nothing changes, so bindings on it stay quiet.
function withUnitValue(map, unit, value) {
  var current = map ? map[unit] : undefined
  if (current === value) return map
  var next = {}
  for (var key in map) if (key !== unit) next[key] = map[key]
  if (value !== undefined) next[unit] = value
  return next
}

// ---- Polkit whitelist

// The rules file the sync step installs (as root via pkexec). Generated
// from the registry's system units; the signature comment lets both the
// panel and polkit.sh tell our file from a hand-edited one.
var POLKIT_RULES_PATH = "/etc/polkit-1/rules.d/49-services-hub.rules"

// FNV-1a 32-bit over the text; hex. Not cryptographic — it only detects
// registry drift between syncs.
function hashSignature(text) {
  var s = String(text || "")
  var h = 0x811c9dc5
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = (h * 0x01000193) >>> 0
  }
  var hex = (h >>> 0).toString(16)
  while (hex.length < 8) hex = "0" + hex
  return hex
}

// Signature of a set of unit names: sorted, joined, hashed.
function unitSetSignature(unitNames) {
  var names = []
  for (var i = 0; i < (unitNames || []).length; i++)
    if (validUnitName(unitNames[i])) names.push(unitNames[i])
  names.sort()
  return hashSignature(names.join("\n"))
}

// The rules file text. Invalid names are skipped; if nothing valid is
// left, the whitelist is empty and every action prompts as usual.
function generatePolkitRules(user, unitNames, signature) {
  var entries = []
  for (var i = 0; i < (unitNames || []).length; i++) {
    if (!validUnitName(unitNames[i])) continue
    entries.push('    "' + unitNames[i] + '": 1')
  }
  return ""
    + "// managed-by=geryruslandi.services-hub signature=" + String(signature || "")
    + "\n// Generated by the Services Hub plugin. Do not edit by hand."
    + "\npolkit.addRule(function(action, subject) {"
    + "\n  if (subject.user !== " + JSON.stringify(String(user || "")) + ") return;"
    + "\n  var whitelist = {"
    + (entries.length ? "\n" + entries.join(",\n") + "\n  " : "")
    + "};"
    + "\n  if (action.id !== \"org.freedesktop.systemd1.manage-units\" &&"
    + "\n      action.id !== \"org.freedesktop.systemd1.manage-unit-files\") return;"
    + "\n  var u = action.lookup(\"unit\") || action.lookup(\"unitfile\") || \"\";"
    + "\n  if (whitelist[u]) return polkit.Result.YES;"
    + "\n});"
    + "\n"
}

// polkit.sh status output: "present <signature>", "absent", or
// "unreadable" (rules.d is root-only; existence can't be checked as the
// invoking user — the caller falls back to its own sync record).
function parsePolkitStatus(text) {
  var line = String(text || "").trim()
  var m = /^present(?:\s+(\S+))?$/.exec(line)
  if (m) return { present: true, signature: m[1] || "" }
  if (line === "absent") return { present: false, signature: "" }
  if (line === "unreadable") return { present: null, signature: "" }
  return null
}

// ---- State file schema

function defaultState() {
  return {
    version: 1,
    registry: [],
    settings: { showInactive: true, hideAutostart: true, refreshIntervalSec: 5 },
    polkit: { signature: "", syncedAt: "", declinedSessionOnly: false, declinedSignature: "" }
  }
}

// Merge stored JSON into the schema: unknown keys dropped, bad values
// replaced by defaults. Never throws.
function normalizeState(raw) {
  var state = defaultState()
  var value = raw
  if (typeof value === "string") {
    try { value = JSON.parse(value) } catch (e) { return state }
  }
  if (!value || typeof value !== "object" || isList(value)) return state
  state.registry = normalizeRegistry(value.registry)
  var s = value.settings
  if (s && typeof s === "object" && !isList(s)) {
    if (typeof s.showInactive === "boolean") state.settings.showInactive = s.showInactive
    if (typeof s.hideAutostart === "boolean") state.settings.hideAutostart = s.hideAutostart
    var n = Number(s.refreshIntervalSec)
    if (isFinite(n)) state.settings.refreshIntervalSec = Math.max(2, Math.min(60, Math.round(n)))
  }
  var p = value.polkit
  if (p && typeof p === "object" && !isList(p)) {
    if (typeof p.signature === "string") state.polkit.signature = p.signature
    if (typeof p.syncedAt === "string") state.polkit.syncedAt = p.syncedAt
    if (typeof p.declinedSessionOnly === "boolean") state.polkit.declinedSessionOnly = p.declinedSessionOnly
    if (typeof p.declinedSignature === "string") state.polkit.declinedSignature = p.declinedSignature
  }
  return state
}

// True when a sync would change something. `installed` is what polkit.sh
// status reported: { present: true|false|null, signature } — null means
// "not checked yet" or "unreadable", where the panel trusts its own sync
// record so the footer is correct before any status round-trip lands.
function polkitNeedsSync(state, systemNames, installed) {
  if (systemUnitNames(state.registry).length === 0) return false
  var wanted = unitSetSignature(systemUnitNames(state.registry))
  var recorded = String(state.polkit.signature || "")
  if (!installed) return recorded !== wanted
  if (installed.present === null) return recorded !== wanted
  if (!installed.present) return true
  return String(installed.signature || "") !== wanted
}

// ---- Coloured logs
//
// logs.sh prints "<priority>\t<line>", with the service's own ANSI colour
// codes kept. These helpers turn that into rich text for the details view:
// the line's severity picks its base colour, the timestamp/name header is
// dimmed, and ANSI colours inside the message are rendered with the theme's
// palette.

// Theme palette from the theme's colors.toml. Named keys (red, bright_red,
// …) win; older themes that only define color0..color15 fall back to those.
function parseThemePalette(text) {
  var values = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*([A-Za-z0-9_]+)\s*=\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)"/.exec(lines[i])
    if (m) values[m[1]] = m[2]
  }
  var names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
  var palette = {}
  for (var n = 0; n < 8; n++) {
    var normal = values[names[n]] || values["color" + n]
    var bright = values["bright_" + names[n]] || values["color" + (n + 8)] || normal
    if (normal) palette[n] = normal
    if (bright) palette[n + 8] = bright
  }
  return palette
}

// error | warning | debug | meta | normal. journald's priority wins when the
// service set one; most services log everything at 6 (info), so keywords in
// the text decide otherwise.
function logSeverity(priority, text) {
  if (priority === "-") return "meta"
  var p = Number(priority)
  if (p <= 3) return "error"
  if (p === 4) return "warning"
  if (p === 7) return "debug"
  var t = String(text || "")
  if (/\b(ERROR|ERR|FATAL|CRITICAL|CRIT|PANIC|EMERG|ALERT)\b/.test(t)
      || /Traceback \(most recent call last\)/.test(t)
      || /\b[A-Z][A-Za-z]*(Error|Exception)\b/.test(t)
      || /(^|:\s+)(error|fatal)(:|\[)/i.test(t))
    return "error"
  if (/\b(WARN|WARNING)\b/.test(t)
      || /\b[A-Z][A-Za-z]*Warning\b/.test(t)
      || /(^|:\s+)warning(:|\[)/i.test(t))
    return "warning"
  return "normal"
}

function stripAnsi(text) {
  return String(text || "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
}

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// xterm 256-colour index to a colour; 0..15 come from the theme palette.
function ansi256(n, palette) {
  if (n < 16) return palette[n] || null
  if (n >= 232) {
    var g = 8 + (n - 232) * 10
    return rgbHex(g, g, g)
  }
  var i = n - 16
  var steps = [0, 95, 135, 175, 215, 255]
  return rgbHex(steps[Math.floor(i / 36)], steps[Math.floor(i / 6) % 6], steps[i % 6])
}

function rgbHex(r, g, b) {
  function h(v) { var s = Math.max(0, Math.min(255, v | 0)).toString(16); return s.length < 2 ? "0" + s : s }
  return "#" + h(r) + h(g) + h(b)
}

// Split text on ANSI SGR sequences into { text, color, bold, dim } runs.
// Other escape sequences are dropped.
function ansiRuns(text, palette) {
  var runs = []
  var state = { color: null, bold: false, dim: false }
  var re = /\x1b\[([0-9;?]*)([A-Za-z])/g
  var last = 0
  var m
  var s = String(text || "")
  function push(t) {
    if (t !== "") runs.push({ text: t, color: state.color, bold: state.bold, dim: state.dim })
  }
  while ((m = re.exec(s)) !== null) {
    push(s.slice(last, m.index))
    last = re.lastIndex
    if (m[2] !== "m") continue
    var codes = m[1] === "" ? [0] : m[1].split(";").map(Number)
    for (var i = 0; i < codes.length; i++) {
      var c = codes[i]
      if (c === 0) state = { color: null, bold: false, dim: false }
      else if (c === 1) state.bold = true
      else if (c === 2) state.dim = true
      else if (c === 22) { state.bold = false; state.dim = false }
      else if (c >= 30 && c <= 37) state.color = palette[c - 30] || null
      else if (c >= 90 && c <= 97) state.color = palette[c - 90 + 8] || null
      else if (c === 39) state.color = null
      else if (c === 38 && codes[i + 1] === 5) { state.color = ansi256(codes[i + 2], palette); i += 2 }
      else if (c === 38 && codes[i + 1] === 2) { state.color = rgbHex(codes[i + 2], codes[i + 3], codes[i + 4]); i += 4 }
      else if (c === 48) i += codes[i + 1] === 5 ? 2 : (codes[i + 1] === 2 ? 4 : 0)
    }
  }
  push(s.slice(last))
  return runs
}

// "Sep 28 03:55:21 python[123]: " (or a continuation line's indent).
function splitLogHeader(line) {
  var m = /^([A-Z][a-z]{2} [ 0-9]\d \d\d:\d\d:\d\d [^:]*?: )/.exec(line)
  if (m) return { head: m[1], body: line.slice(m[1].length) }
  var indent = /^( +)/.exec(line)
  if (indent) return { head: indent[1], body: line.slice(indent[1].length) }
  return { head: "", body: line }
}

// Rich text for the logs view. `colors` holds foreground, dim, error,
// warning and the theme `palette` (see parseThemePalette).
function logsHtml(text, colors) {
  var palette = colors.palette || {}
  var base = {
    error: colors.error, warning: colors.warning, debug: colors.dim,
    meta: colors.dim, normal: colors.foreground
  }
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var tab = line.indexOf("\t")
    var priority = tab >= 0 ? line.slice(0, tab) : "6"
    var content = tab >= 0 ? line.slice(tab + 1) : line
    var parts = splitLogHeader(content)
    var severity = logSeverity(priority, stripAnsi(parts.body))
    var html = parts.head !== "" ? '<span style="color:' + colors.dim + '">' + escapeHtml(parts.head) + "</span>" : ""
    var runs = ansiRuns(parts.body, palette)
    for (var r = 0; r < runs.length; r++) {
      var run = runs[r]
      var color = run.color || (run.dim ? colors.dim : base[severity])
      var piece = '<span style="color:' + color + '">' + escapeHtml(run.text) + "</span>"
      html += run.bold ? "<b>" + piece + "</b>" : piece
    }
    out.push(html)
  }
  return '<div style="white-space:pre-wrap">' + out.join("<br>") + "</div>"
}

// Placeholder text ("Loading…") in the same rich-text frame.
function plainHtml(text, color) {
  return '<div style="white-space:pre-wrap"><span style="color:' + color + '">' + escapeHtml(text) + "</span></div>"
}
