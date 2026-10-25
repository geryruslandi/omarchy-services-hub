# Services Hub

A bar-free Omarchy shell plugin for service management: one hub that lists the
services **you** register — user services (`systemctl --user`) and system
services — with a start/stop switch, real RAM and VRAM per service, a details
view with restart / start-at-login / live coloured logs, and an optional
per-unit polkit whitelist so system services don't ask for a password every
time.

Ported from the MIT-licensed
[gabepsilva/omarchy-user-services](https://github.com/gabepsilva/omarchy-user-services)
(same panel UI and measurement approach), extended with a service registry, an
add-service form, and system-scope support. No favorites.

## Install

Copy this folder into `~/.config/omarchy/plugins/geryruslandi.services-hub/`,
then:

```
omarchy plugin enable geryruslandi.services-hub
```

That is the only step. On the next shell start the plugin:

- installs `~/.local/share/applications/services-hub.desktop`, so the panel is
  searchable in the launcher as **"Services hub"**;
- adds a **Services hub** row to the root menu (with aliases `services` and
  `hub`);
- leaves everything else alone until you register a system service.

## Open the panel

- Search **"Services hub"** in the launcher or the root menu.
- Or run: `omarchy-shell shell toggle geryruslandi.services-hub`.

There is no bar icon by design.

## Register services

Open the panel → **Add** (or press `a`):

1. **Pick the scope first** — *User service* or *System service*; the dropdown
   lists that scope's installed services (`systemctl [--user]
   list-unit-files`).
2. Pick a service in the searchable dropdown and press **Add service**.

Registered services are listed in the panel (failed first, then running, then
stopped). Remove one with the trash button (the service itself is not touched).

## Controls

Per row: the switch starts/stops the service; **Details** (`d`) opens PID,
uptime, RAM, VRAM, CPU, tasks and the live journal (newest 300 lines,
capped at 64 KiB, coloured with the theme palette); **Restart** (`r`).

In the details view the **Start at login** switch flips
`systemctl [--user] enable/disable`.

Keyboard: `j`/`k` or arrows move, `Enter`/`Space` start/stop, `d` details,
`r` restart, `a` add, `/` filter, `R` refresh, `Delete` remove, `Esc` close.
In details: `e` start-at-login, `f` follow logs in a terminal.

Session-critical services (`pipewire`, `dbus-broker`, `NetworkManager`, …)
ask for confirmation before they are stopped or restarted.

## System services and polkit

Reading status, RAM/VRAM, logs and the enable state of system services needs
no privileges. **Changing** them (start/stop/restart/enable/disable) asks
systemd over D-Bus, where polkit decides:

- **Without a whitelist**: systemd's default policy (`auth_admin_keep`) opens
  the polkit password dialog; one successful authentication is remembered for
  a while. Dismissing it shows "Not authorized …" in the panel.
- **With the per-unit whitelist**: the plugin generates
  `/etc/polkit-1/rules.d/49-services-hub.rules` allowing exactly the
  registered system units **and their socket/timer companions** — and only
  start/stop/restart and enable/disable on them. Those actions become
  passwordless.

The panel footer shows the whitelist state and has **Sync** / **Remove**
buttons. The plugin offers to sync automatically once per shell session when
you register the first system service or change the registry — dismissing the
password prompt keeps the ask-your-password behaviour until you sync (no
nagging within the session).

Sync/Remove themselves always ask for your password: they are root file
writes (`pkexec`), and whitelisting `org.freedesktop.policykit.exec` would
let any script run arbitrary commands as root — deliberately not done.

## Settings

Edited in the panel (persisted in `~/.local/state/omarchy/services-hub.json`
together with the registry):

| Key | Default | Meaning |
| --- | --- | --- |
| `showInactive` | `true` | List stopped services too |
| `hideAutostart` | `true` | Hide generated `app-*@autostart.service` |
| `refreshIntervalSec` | `5` | Poll interval while the panel is open (2–60) |

## How memory is measured

Same as the reference widget:

- **RAM** (`memory.sh`): `anon + shmem + kernel` from each service's cgroup
  `memory.stat` (per scope). Page cache is left out — systemd's
  `MemoryCurrent` includes it, which is why figures here look smaller.
- **VRAM** (`vram.sh`): per-process `drm-total-vram` from
  `/proc/<pid>/fdinfo`, plus `nvidia-smi` when present (CUDA memory lives
  outside DRM). Processes are mapped to services through their cgroups —
  user services *and* system services. A unit name that exists in both
  scopes is reported once.

## What it runs

Only `systemctl`, `journalctl`, the bundled read-only scripts
(`memory.sh`, `vram.sh`, `logs.sh`), `nvidia-smi` if present, and the setup
helpers (`setup.sh`, `polkit.sh`). Every read runs under `timeout` (10s) and
an output cap (`capped.sh`, 1 MiB); actions run under a 30s timeout, or 120s
when they go through `pkexec` (the password dialog needs its time). It never
connects to the network. Privileged changes happen only through `pkexec` and
only when you act.

## IPC

Panel toggle (works whether open or closed):

```
omarchy-shell shell toggle geryruslandi.services-hub
```

Actions (the panel must be open):

```
omarchy-shell geryruslandi.services-hub list
omarchy-shell geryruslandi.services-hub start '{"unit":"x.service","scope":"user"}'
omarchy-shell geryruslandi.services-hub stop|restart|details|add|remove '<same json>'
omarchy-shell geryruslandi.services-hub polkitSync
omarchy-shell geryruslandi.services-hub polkitRemove
omarchy-shell geryruslandi.services-hub polkitStatus
omarchy-shell geryruslandi.services-hub debug          # live state dump
```

`"user:x.service"` is accepted wherever the JSON is. The same methods also
answer to `omarchy-shell shell call geryruslandi.services-hub <method> "{}"`.

## Remove

```
bash ~/.config/omarchy/plugins/geryruslandi.services-hub/setup.sh clean   # optional: removes launcher entry + menu row now
omarchy plugin disable geryruslandi.services-hub
omarchy plugin remove geryruslandi.services-hub
```

The registry lives in `~/.local/state/omarchy/services-hub.json` and survives
updates; delete it to reset the hub.

## Development

```
node --test test/          # Model.js is pure logic, needs only node
```

License: MIT (see the upstream repo for its MIT licence text; this port keeps
the same terms and credit).
