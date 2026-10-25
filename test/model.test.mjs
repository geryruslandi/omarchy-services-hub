// Tests for Model.js, the pure helpers behind ServicesHub.qml.
// Run with: node --test test/
//
// Ported from the MIT-licensed gabepsilva/omarchy-user-services test suite,
// with the favorites tests replaced by service-registry tests and new tests
// for scopes, the dropdown, polkit generation and state normalization.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

// Model.js is a QML JavaScript library: its first line is `.pragma library`,
// which is not JavaScript. Drop it and evaluate the rest in a sandbox.
const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = vm.createContext({})
vm.runInContext(source, M)

// vm objects come from another realm, so compare through JSON — both sides.
const same = (actual, expected) => assert.deepEqual(
  JSON.parse(JSON.stringify(actual === undefined ? null : actual)),
  JSON.parse(JSON.stringify(expected === undefined ? null : expected)))

const unit = (name, active = "active", sub = "running", load = "loaded", description = "") =>
  ({ unit: name, load, active, sub, description })

test("parseUnits reads systemctl JSON and rejects junk", () => {
  const units = M.parseUnits(JSON.stringify([
    { unit: "a.service", load: "loaded", active: "active", sub: "running", description: "A" },
    { unit: "", load: "loaded" },
    {}
  ]))
  same(units, [unit("a.service", "active", "running", "loaded", "A")])
  assert.equal(M.parseUnits("not json"), null)
  assert.equal(M.parseUnits("{}"), null)
  same(M.parseUnits(""), [])
})

test("display names unescape systemd escapes and drop .service", () => {
  assert.equal(M.displayName("app-claude\\x2ddesktop@autostart.service"), "app-claude-desktop@autostart")
  assert.equal(M.displayName("kokoro.service"), "kokoro")
})

test("running, failed and transitioning states", () => {
  assert.equal(M.isRunning(unit("a", "active")), true)
  assert.equal(M.isRunning(unit("a", "activating")), true)
  assert.equal(M.isRunning(unit("a", "reloading")), true)
  assert.equal(M.isRunning(unit("a", "inactive")), false)
  assert.equal(M.isRunning(null), false)
  assert.equal(M.isFailed(unit("a", "failed")), true)
  assert.equal(M.isTransitioning(unit("a", "deactivating")), true)
  assert.equal(M.isTransitioning(unit("a", "active")), false)
})

test("filterUnits hides noise, filters, and sorts failed, running, stopped", () => {
  const units = [
    unit("zeta.service", "inactive", "dead"),
    unit("alpha.service"),
    unit("broken.service", "failed", "failed"),
    unit("gone.service", "inactive", "dead", "not-found"),
    unit("dbus-:1.2-x@0.service"),
    unit("app-foo@autostart.service"),
    unit("beta.service", "active", "running", "loaded", "Pipe thing")
  ]
  const names = (list) => Array.from(list, (u) => u.unit)

  same(names(M.filterUnits(units, { showInactive: true, hideAutostart: true })),
    ["broken.service", "alpha.service", "beta.service", "zeta.service"])
  same(names(M.filterUnits(units, { showInactive: false, hideAutostart: true })),
    ["broken.service", "alpha.service", "beta.service"])
  same(names(M.filterUnits(units, { showInactive: true, hideAutostart: false })),
    ["broken.service", "alpha.service", "app-foo@autostart.service", "beta.service", "zeta.service"])
  same(names(M.filterUnits(units, { showInactive: true, query: "PIPE" })), ["beta.service"])
  same(names(M.filterUnits(units, { showInactive: true, query: "  alp " })), ["alpha.service"])
})

test("counts", () => {
  const units = [unit("a"), unit("b", "failed", "failed"), unit("c", "inactive", "dead")]
  assert.equal(M.countRunning(units), 1)
  assert.equal(M.countFailed(units), 1)
  assert.equal(M.countRunning(null), 0)
})

test("elide collapses whitespace and truncates", () => {
  assert.equal(M.elide("  a \n  b  "), "a b")
  assert.equal(M.elide("abcdef", 4), "abc…")
})

// ---- Registry

test("validUnitName accepts only plain .service units with systemd charset", () => {
  assert.equal(M.validUnitName("kokoro.service"), true)
  assert.equal(M.validUnitName("app-foo@autostart.service"), true)
  assert.equal(M.validUnitName("user@1000.service"), true)
  assert.equal(M.validUnitName("kokoro"), false)
  assert.equal(M.validUnitName("kokoro.socket"), false)
  assert.equal(M.validUnitName("tmpl@.service"), false)
  assert.equal(M.validUnitName("with space.service"), false)
  assert.equal(M.validUnitName(""), false)
  assert.equal(M.validUnitName("../escape.service"), false)
  assert.equal(M.validUnitName(null), false)
})

test("scopeKey disambiguates the same unit across scopes", () => {
  assert.equal(M.scopeKey("user", "a.service"), "user:a.service")
  assert.equal(M.scopeKey("system", "a.service"), "system:a.service")
})

test("normalizeRegistry keeps valid entries in order and dedupes", () => {
  same(M.normalizeRegistry([
    { unit: "a.service", scope: "user" },
    { unit: "a.service", scope: "user" },     // dupe
    { unit: "b.service" },                    // scope defaults to user
    { unit: "c.service", scope: "system" },
    { unit: "bad", scope: "user" },           // no .service
    { unit: "d.service", scope: "docker" },   // bad scope
    null
  ]), [
    { unit: "a.service", scope: "user" },
    { unit: "b.service", scope: "user" },
    { unit: "c.service", scope: "system" }
  ])
  same(M.normalizeRegistry("nope"), [])
})

test("addToRegistry validates and rejects duplicates; remove is idempotent", () => {
  let res = M.addToRegistry([], "user", "a.service")
  assert.equal(res.error, "")
  same(res.list, [{ unit: "a.service", scope: "user" }])

  res = M.addToRegistry(res.list, "user", "a.service")
  assert.equal(res.error, "a is already registered (user).")
  same(res.list, [{ unit: "a.service", scope: "user" }])

  res = M.addToRegistry(res.list, "system", "a.service")
  assert.equal(res.error, "") // same unit, other scope: fine

  same(M.addToRegistry([], "docker", "a.service").error, "Pick user or system first.")
  same(M.addToRegistry([], "user", "nope").error, "Not a service unit name.")

  same(M.removeFromRegistry([{ unit: "a.service", scope: "user" }, { unit: "b.service", scope: "system" }], "system", "b.service"),
    [{ unit: "a.service", scope: "user" }])
  same(M.removeFromRegistry([{ unit: "a.service", scope: "user" }], "system", "a.service"),
    [{ unit: "a.service", scope: "user" }])
})

test("registry unit names per scope", () => {
  const registry = [{ unit: "a.service", scope: "user" }, { unit: "c.service", scope: "system" }, { unit: "b.service", scope: "system" }]
  same(M.registryUnitNames(registry, "user"), ["a.service"])
  same(M.registryUnitNames(registry, "system"), ["c.service", "b.service"])
  same(M.registryUnitNames(registry), ["a.service", "c.service", "b.service"])
  same(M.systemUnitNames(registry), ["c.service", "b.service"])
})

test("registeredRows merge both scopes with placeholders, failed first", () => {
  const userMap = M.unitMap([unit("a.service")])
  const systemMap = M.unitMap([unit("c.service", "failed", "failed")])
  const rows = M.registeredRows([
    { unit: "a.service", scope: "user" },
    { unit: "gone.service", scope: "system" },
    { unit: "c.service", scope: "system" }
  ], userMap, systemMap)
  same(rows.map((r) => r.unit), ["c.service", "a.service", "gone.service"])
  same(rows.map((r) => r.scope), ["system", "user", "system"])
  assert.equal(rows[2].unitData.load, "not-found")
})

test("filterRegistered filters and keeps removable not-found rows", () => {
  const rows = M.registeredRows([
    { unit: "zeta.service", scope: "user" },
    { unit: "app-foo@autostart.service", scope: "user" },
    { unit: "alpha.service", scope: "system" }
  ], M.unitMap([unit("zeta.service", "inactive", "dead"), unit("app-foo@autostart.service", "inactive", "dead")]), {})

  same(rows.map((r) => r.unit), ["alpha.service", "app-foo@autostart.service", "zeta.service"])
  same(M.filterRegistered(rows, { showInactive: true, hideAutostart: true }).map((r) => r.unit),
    ["alpha.service", "zeta.service"])
  same(M.filterRegistered(rows, { showInactive: true, hideAutostart: true, query: "SYS" }).map((r) => r.unit),
    ["alpha.service"])
  same(M.filterRegistered(rows, { showInactive: true, hideAutostart: false, query: "foo" }).map((r) => r.unit),
    ["app-foo@autostart.service"])
})

test("dropdownItems lists installed services with states, minus templates and registered", () => {
  const states = {
    "a.service": "enabled",
    "b.service": "disabled",
    "tmpl@.service": "disabled",
    "inst@1.service": "disabled",
    "static.service": "static"
  }
  const items = M.dropdownItems(states, [{ unit: "b.service", scope: "user" }], "user")
  same(items, [
    { value: "a.service", label: "a — enabled" },
    { value: "inst@1.service", label: "inst@1 — disabled" },
    { value: "static.service", label: "static — static" }
  ])
  // The same states under the system scope include the registered b.
  assert.ok(M.dropdownItems(states, [{ unit: "b.service", scope: "user" }], "system")
    .some((o) => o.value === "b.service"))
})

test("unitMap and registryUnit placeholder for missing units", () => {
  const map = M.unitMap([unit("a.service")])
  assert.equal(map["a.service"].unit, "a.service")
  same(M.registryUnit(map, "gone.service"),
    { unit: "gone.service", load: "not-found", active: "inactive", sub: "not loaded", description: "" })
})

test("descriptionOf hides descriptions that just repeat the unit name", () => {
  assert.equal(M.descriptionOf(unit("a.service", "active", "running", "loaded", "Thing")), "Thing")
  assert.equal(M.descriptionOf(unit("a.service", "active", "running", "loaded", "a.service")), "")
  assert.equal(M.descriptionOf(null), "")
})

test("start-at-login states", () => {
  assert.equal(M.canToggleEnable("enabled"), true)
  assert.equal(M.canToggleEnable("disabled"), true)
  assert.equal(M.canToggleEnable("static"), false)
  assert.equal(M.isEnabledState("enabled-runtime"), true)
  assert.equal(M.isEnabledState("disabled"), false)
  assert.equal(M.enableStateHint(""), "Checking…")
  assert.equal(M.enableStateHint("weird"), "weird")
})

test("critical units cover both scopes' session plumbing", () => {
  assert.equal(M.isCritical("pipewire.service"), true)
  assert.equal(M.isCritical("NetworkManager.service"), true)
  assert.equal(M.isCritical("kokoro.service"), false)
  assert.equal(M.isCritical(null), false)
})

test("parseShow splits KEY=value blocks", () => {
  same(M.parseShow("Id=a.service\nMainPID=12\n\nId=b.service\nMainPID=0\n"),
    [{ Id: "a.service", MainPID: "12" }, { Id: "b.service", MainPID: "0" }])
  same(M.parseShow("ExecStart={ path=/bin/x ; argv[]=/bin/x a=b }"),
    [{ ExecStart: "{ path=/bin/x ; argv[]=/bin/x a=b }" }])
})

test("numberOrNull treats systemd's unset values as null", () => {
  assert.equal(M.numberOrNull("42"), 42)
  assert.equal(M.numberOrNull("[not set]"), null)
  assert.equal(M.numberOrNull("18446744073709551615"), null)
  assert.equal(M.numberOrNull("infinity"), null)
  assert.equal(M.numberOrNull(""), null)
})

test("memoryLines parses unit=bytes output", () => {
  same(M.memoryLines("a.service=1024\nb@x=y.service=2048\nbad\nzero.service=0\n"),
    { "a.service": 1024, "b@x=y.service": 2048 })
})

test("formatting", () => {
  assert.equal(M.formatBytes(900), "900B")
  assert.equal(M.formatBytes(532480), "520K")
  assert.equal(M.formatBytes(14626816), "14M")
  assert.equal(M.formatBytes(2630627328), "2.4G")
  assert.equal(M.formatBytes(null), "—")
  assert.equal(M.formatDuration(59), "59s")
  assert.equal(M.formatDuration(3725), "1h 2m")
  assert.equal(M.formatDuration(200000), "2d 7h")
  assert.equal(M.formatDuration(-1), "—")
  assert.equal(M.formatCpu(22326973000), "22s")
  assert.equal(M.formatCpu(null), "—")
  assert.equal(M.unixTimestamp("@1790576006"), 1790576006)
  assert.equal(M.unixTimestamp("n/a"), null)
})

test("memoryTooltip lines up RAM and VRAM", () => {
  assert.equal(M.memoryTooltip(128974848, 1181116006), "RAM:  123M\nVRAM: 1.1G")
  assert.equal(M.memoryTooltip(128974848, undefined), "RAM:  123M")
})

test("action status wording", () => {
  assert.equal(M.busyLabel("restart"), "Restarting…")
  assert.equal(M.busyLabel("other"), "Working…")
  assert.equal(M.doneLabel("stop"), "Stopped")
  assert.equal(M.doneLabel("enable"), "Enabled")
  assert.equal(M.doneLabel("other"), "Done")
})

test("withUnitValue sets, removes, and keeps identity when unchanged", () => {
  const map = M.memoryLines("a.service=1\nb.service=2\n")
  assert.equal(M.withUnitValue(map, "a.service", 1), map)
  assert.equal(M.withUnitValue(map, "gone.service", undefined), map)
  same(M.withUnitValue(map, "a.service", 5), { "a.service": 5, "b.service": 2 })
  same(M.withUnitValue(map, "a.service", undefined), { "b.service": 2 })
  same(map, { "a.service": 1, "b.service": 2 })
})

test("parseThemePalette reads named colours and falls back to colorN", () => {
  const named = M.parseThemePalette('red = "#c34043"\nbright_red = "#e82424"\ngreen = "#76946a"\nmode = "dark"\n')
  assert.equal(named[1], "#c34043")
  assert.equal(named[9], "#e82424")
  assert.equal(named[2], "#76946a")
  assert.equal(named[10], "#76946a")  // no bright_green: reuse green
  const numbered = M.parseThemePalette('color1 = "#aa0000"\ncolor9 = "#ff0000"\n')
  assert.equal(named[1], "#c34043")
  assert.equal(numbered[1], "#aa0000")
  assert.equal(numbered[9], "#ff0000")
  same(M.parseThemePalette(""), {})
})

test("logSeverity: journald priority first, then keywords", () => {
  assert.equal(M.logSeverity("3", "all good"), "error")
  assert.equal(M.logSeverity("4", "all good"), "warning")
  assert.equal(M.logSeverity("7", "ERROR"), "debug")
  assert.equal(M.logSeverity("-", "… older log output"), "meta")
  assert.equal(M.logSeverity("6", "2026-09-27T19:00:49Z  WARN device busy"), "warning")
  assert.equal(M.logSeverity("6", "2026-09-27T19:00:49Z ERROR boom"), "error")
  assert.equal(M.logSeverity("6", "Traceback (most recent call last):"), "error")
  assert.equal(M.logSeverity("6", "ValueError: bad input"), "error")
  assert.equal(M.logSeverity("6", "_script.py:1491: FutureWarning: deprecated"), "warning")
  assert.equal(M.logSeverity("6", "error: could not open file"), "error")
  assert.equal(M.logSeverity("6", "0 errors, 2 warnings found"), "normal")
  assert.equal(M.logSeverity("6", "Started Kokoro daemon."), "normal")
})

test("ansiRuns maps SGR codes to theme colours", () => {
  const palette = { 1: "#red", 2: "#green", 3: "#yellow", 10: "#bgreen" }
  same(M.ansiRuns("\x1b[2mtime\x1b[0m \x1b[32m INFO\x1b[0m msg", palette), [
    { text: "time", color: null, bold: false, dim: true },
    { text: " ", color: null, bold: false, dim: false },
    { text: " INFO", color: "#green", bold: false, dim: false },
    { text: " msg", color: null, bold: false, dim: false }
  ])
  same(M.ansiRuns("\x1b[1;92mok\x1b[22;39m.", palette), [
    { text: "ok", color: "#bgreen", bold: true, dim: false },
    { text: ".", color: null, bold: false, dim: false }
  ])
  assert.equal(M.ansiRuns("\x1b[38;2;255;0;16mx", palette)[0].color, "#ff0010")
  assert.equal(M.ansiRuns("\x1b[38;5;196mx", palette)[0].color, "#ff0000")
  same(M.ansiRuns("a\x1b[Kb", palette).map((r) => r.text), ["a", "b"])
  assert.equal(M.stripAnsi("\x1b[33mWARN\x1b[0m x"), "WARN x")
})

test("logsHtml dims headers, colours by severity, escapes markup", () => {
  const colors = { foreground: "#fg", dim: "#dim", error: "#err", warning: "#warn", palette: { 2: "#green" } }
  const html = M.logsHtml(
    "6\tSep 28 03:55:21 python[12]: <b>hi</b> & ok\n" +
    "3\tSep 28 03:55:22 python[12]: crashed\n" +
    "6\t                            continuation\n" +
    "6\tSep 28 03:55:23 voxtype[9]: \x1b[32m INFO\x1b[0m WARN low disk\n" +
    "-\t… older log output not shown\n", colors)
  assert.match(html, /^<div style="white-space:pre-wrap">/)
  assert.ok(html.includes('<span style="color:#dim">Sep 28 03:55:21 python[12]: </span><span style="color:#fg">&lt;b&gt;hi&lt;/b&gt; &amp; ok</span>'))
  assert.ok(html.includes('<span style="color:#err">crashed</span>'))
  assert.ok(html.includes('<span style="color:#dim">                            </span><span style="color:#fg">continuation</span>'))
  assert.ok(html.includes('<span style="color:#green"> INFO</span><span style="color:#warn"> WARN low disk</span>'))
  assert.ok(html.includes('<span style="color:#dim">… older log output not shown</span>'))
  assert.equal(html.split("<br>").length, 5)
  assert.equal(M.plainHtml("a<b", "#c"), '<div style="white-space:pre-wrap"><span style="color:#c">a&lt;b</span></div>')
})

test("parseUnitFiles maps unit files to their state", () => {
  same(M.parseUnitFiles(JSON.stringify([
    { unit_file: "a.service", state: "enabled", preset: "enabled" },
    { unit_file: "", state: "disabled" },
    {}
  ])), { "a.service": "enabled" })
  assert.equal(M.parseUnitFiles("not json"), null)
  assert.equal(M.parseUnitFiles("{}"), null)
})

test("withInstalledUnits lists unloaded enabled and disabled services as stopped", () => {
  const loaded = [unit("a.service")]
  const merged = M.withInstalledUnits(loaded, {
    "a.service": "enabled",
    "b.service": "disabled",
    "c.service": "enabled",
    "d.service": "static",
    "e.service": "masked",
    "tmpl@.service": "disabled"
  })
  same(merged, [
    unit("a.service"),
    unit("b.service", "inactive", "dead", "not-loaded"),
    unit("c.service", "inactive", "dead", "not-loaded")
  ])
  assert.equal(loaded.length, 1)
  same(M.withInstalledUnits(null, null), [])
})

test("unloaded installed units are listed and startable; missing ones are not", () => {
  const units = M.withInstalledUnits([unit("gone.service", "inactive", "dead", "not-found")],
    { "b.service": "disabled" })
  same(Array.from(M.filterUnits(units, { showInactive: true }), (u) => u.unit), ["b.service"])
  assert.equal(M.isStartable(M.registryUnit(M.unitMap(units), "b.service")), true)
  assert.equal(M.isStartable(M.registryUnit(M.unitMap(units), "nope.service")), false)
  assert.equal(M.isStartable(null), false)
})

test("commands run under timeout, and its exits read as timeouts", () => {
  same(M.timed(10, ["systemctl", "--user", "stop", "--", "a.service"]),
    ["timeout", "--kill-after=2", "10s", "systemctl", "--user", "stop", "--", "a.service"])
  assert.equal(M.timedOut(124, 0), true)
  assert.equal(M.timedOut(137, 0), true)
  assert.equal(M.timedOut(9, 1), true)
  assert.equal(M.timedOut(1, 0), false)
  assert.equal(M.timedOut(0, 0), false)
  assert.equal(M.actionTimeoutText("stop", "kokoro.service"),
    "Stop kokoro is taking over 30s; systemd is still working on it")
})

test("commands run under an output cap inside the timeout", () => {
  same(M.bounded(10, "/p/capped.sh", ["systemctl", "--user", "list-units"]),
    ["timeout", "--kill-after=2", "10s", "bash", "/p/capped.sh", "1048576", "systemctl", "--user", "list-units"])
  assert.equal(M.overflowed(90, 0), true)
  assert.equal(M.overflowed(90, 1), false)
  assert.equal(M.overflowed(0, 0), false)
  assert.equal(M.overflowed(124, 0), false)
  assert.equal(M.overflowText("systemctl --user list-units"),
    "systemctl --user list-units printed over 1 MiB; not shown")
})

// ---- Polkit whitelist

test("unitSetSignature is stable, order-insensitive, and skips junk", () => {
  const a = M.unitSetSignature(["b.service", "a.service", "bad"])
  const b = M.unitSetSignature(["a.service", "b.service"])
  assert.equal(a, b)
  assert.equal(a, M.unitSetSignature(["b.service", "a.service"]))
  assert.equal(M.unitSetSignature([]), M.unitSetSignature([]))
  assert.equal(M.unitSetSignature(["x y.service", "a.service"]), M.unitSetSignature(["a.service"]))
})

test("generatePolkitRules whitelists exactly the given units for two actions", () => {
  const text = M.generatePolkitRules("tester", ["docker.service", "libvirtd.service", "bad name.service"], "0badc0de")
  assert.ok(text.startsWith("// managed-by=geryruslandi.services-hub signature=0badc0de"))
  assert.ok(text.includes('if (subject.user !== "tester") return;'))
  assert.ok(text.includes('"docker.service": 1'))
  assert.ok(text.includes('"libvirtd.service": 1'))
  assert.ok(!text.includes("bad name.service"))
  assert.ok(text.includes("org.freedesktop.systemd1.manage-units"))
  assert.ok(text.includes("org.freedesktop.systemd1.manage-unit-files"))
  assert.ok(text.includes('action.lookup("unit")'))
  assert.ok(text.includes('action.lookup("unitfile")'))
  assert.ok(text.includes("polkit.Result.YES"))
  // Empty whitelist is valid and allows nothing.
  const empty = M.generatePolkitRules("tester", [], "sig")
  assert.ok(!empty.includes('": 1'))
})

test("parsePolkitStatus reads polkit.sh output", () => {
  same(M.parsePolkitStatus("present 0badc0de\n"), { present: true, signature: "0badc0de" })
  same(M.parsePolkitStatus("present\n"), { present: true, signature: "" })
  same(M.parsePolkitStatus("absent\n"), { present: false, signature: "" })
  same(M.parsePolkitStatus("unreadable\n"), { present: null, signature: "" })
  assert.equal(M.parsePolkitStatus("junk"), null)
  assert.equal(M.parsePolkitStatus(""), null)
})

// ---- State file

test("defaultState has the documented defaults", () => {
  same(M.defaultState(), {
    version: 1,
    registry: [],
    settings: { showInactive: true, hideAutostart: true, refreshIntervalSec: 5 },
    polkit: { signature: "", syncedAt: "", declinedSessionOnly: false, declinedSignature: "" }
  })
})

test("normalizeState merges stored JSON, drops junk, clamps the interval", () => {
  same(M.normalizeState('{"version":1,"registry":[{"unit":"a.service","scope":"system"},{"unit":"bad"}],'
    + '"settings":{"showInactive":false,"refreshIntervalSec":1,"junk":1},'
    + '"polkit":{"signature":"abc","declinedSessionOnly":true},"extra":"x"}'),
    {
      version: 1,
      registry: [{ unit: "a.service", scope: "system" }],
      settings: { showInactive: false, hideAutostart: true, refreshIntervalSec: 2 },
      polkit: { signature: "abc", syncedAt: "", declinedSessionOnly: true, declinedSignature: "" }
    })
  same(M.normalizeState("not json"), M.defaultState())
  same(M.normalizeState(null), M.defaultState())
  same(M.normalizeState([]), M.defaultState())
  same(M.normalizeState('{"registry":"nope"}'), M.defaultState())
})

test("companion units derive socket/timer companions; managedUnits merges and dedupes", () => {
  same(M.companionUnits("docker.service"), ["docker.socket", "docker.timer"])
  same(M.companionUnits("user@1000.service"), ["user@1000.socket", "user@1000.timer"])
  same(M.companionUnits("docker.socket"), [])  // only services have companions
  same(M.companionUnits(""), [])
  same(M.managedUnits([{ unit: "docker.service", scope: "system" }], "system"),
    ["docker.service", "docker.socket", "docker.timer"])
  same(M.managedUnits([{ unit: "a.service", scope: "user" }], "system"), [])
  // Two services: services first, then companions, deduped.
  same(M.managedUnits([
    { unit: "a.service", scope: "system" },
    { unit: "b.service", scope: "system" }
  ], "system"), ["a.service", "b.service", "a.socket", "a.timer", "b.socket", "b.timer"])
})

test("polkitNeedsSync: no system units means never; absent or drifted means yes; unreadable trusts the record", () => {
  const state = { registry: [{ unit: "a.service", scope: "user" }], polkit: {} }
  assert.equal(M.polkitNeedsSync(state, [], { present: true, signature: "x" }), false)

  const withSystem = { registry: [{ unit: "a.service", scope: "user" }, { unit: "c.service", scope: "system" }], polkit: {} }
  assert.equal(M.polkitNeedsSync(withSystem, [], null), true)
  assert.equal(M.polkitNeedsSync(withSystem, [], { present: false, signature: "" }), true)
  assert.equal(M.polkitNeedsSync(withSystem, [], { present: true, signature: M.unitSetSignature(["c.service"]) }), false)
  assert.equal(M.polkitNeedsSync(withSystem, [], { present: true, signature: "stale" }), true)

  const synced = { registry: withSystem.registry, polkit: { signature: M.unitSetSignature(["c.service"]) } }
  assert.equal(M.polkitNeedsSync(synced, [], { present: null, signature: "" }), false)
  // Unknown status (not checked yet) trusts the sync record, so the footer
  // is correct immediately after a sync without waiting for a status run.
  assert.equal(M.polkitNeedsSync(synced, [], null), false)
  const drifted = { registry: withSystem.registry, polkit: { signature: "old" } }
  assert.equal(M.polkitNeedsSync(drifted, [], { present: null, signature: "" }), true)
  assert.equal(M.polkitNeedsSync(drifted, [], null), true)
})
