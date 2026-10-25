#!/bin/bash
# Services Hub plugin self-setup. Keeps two user-level integration points in
# sync so the panel is reachable without any manual configuration:
#   1. ~/.local/share/applications/services-hub.desktop — the launcher app
#      entry (searched as "Services hub").
#   2. one marked block in ~/.config/omarchy/extensions/omarchy-menu.jsonc —
#      a root-menu row for the same thing.
#   install   write/refresh both (idempotent)
#   clean     remove both (runs when the plugin is disabled)
# User-level only; no root is involved.

set -euo pipefail

# Dash can't run this (BASH_SOURCE, [[ ]], local). Re-exec under bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ID=geryruslandi.services-hub
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP="$DESKTOP_DIR/services-hub.desktop"
BEGIN="  // >>> $ID (managed by the Services Hub plugin; removed when it is disabled)"
END="  // <<< $ID"

refresh() { omarchy menu refresh >/dev/null 2>&1 || true; }

block() {
  # The action guards itself: when the plugin is no longer enabled in
  # shell.json, clicking the (then dead) entry removes the artifacts instead.
  local guard
  guard="sh -c 'if grep -q $ID $HOME/.config/omarchy/shell.json; then exec omarchy-shell shell toggle $ID; else sh $DIR/setup.sh clean 2>/dev/null; fi'"
  cat <<EOF
$BEGIN
  "services-hub": {"icon":"󰒋","label":"Services hub",
    "action":"$guard",
    "aliases":["services","hub"],
    "description":"Start, stop and inspect your registered user and system services"},
$END
EOF
}

install_desktop() {
  mkdir -p "$DESKTOP_DIR"
  if ! cmp -s -- "$DIR/services-hub.desktop" "$DESKTOP" 2>/dev/null; then
    tmp=$(mktemp "$DESKTOP_DIR/.services-hub.XXXXXX")
    cat "$DIR/services-hub.desktop" >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$DESKTOP"
  fi
}

# Same marker protocol and locking as the HyprCapture plugin's menu bridge:
# an incomplete marker pair never consumes unrelated user entries.
menu_edit() {
  local action=$1 target tmp payload=""
  [[ $action == install || -f $MENU ]] || return 0
  mkdir -p "$(dirname "$MENU")"
  exec 8>"$(dirname "$MENU")/.omarchy-menu.lock"
  flock 8
  target=$(readlink -f -- "$MENU") || target="$MENU"
  if [[ -f $target ]] && ! awk '$0 ~ /^[[:space:]]*\{[[:space:]]*$/ { found=1 } END { exit !found }' "$target"; then
    echo "Services Hub: menu extension has no standalone { line; leaving it unchanged" >&2
    return 0
  fi
  tmp=$(mktemp "$(dirname "$target")/.omarchy-menu.XXXXXX")
  # Fires at script exit, after this function's locals are gone; the guard
  # keeps set -u quiet when nothing is pending.
  trap 'if [ -n "${tmp:-}" ]; then rm -f -- "$tmp" "$tmp.insert"; fi' EXIT
  [[ $action == install ]] && payload="$(block)"
  if [[ -f $target ]]; then
    if ! OMARCHY_BEGIN=$BEGIN OMARCHY_END=$END awk '
      $0 == ENVIRON["OMARCHY_BEGIN"] { if (skip) bad=1; skip=1 }
      $0 == ENVIRON["OMARCHY_END"] { skip=0 }
      END { exit (skip || bad) }
    ' "$target"; then
      echo "Services Hub: incomplete managed menu block; leaving it unchanged" >&2
      return 0
    fi
    OMARCHY_BEGIN=$BEGIN OMARCHY_END=$END OMARCHY_BLOCK="$payload" awk '
      BEGIN { begin=ENVIRON["OMARCHY_BEGIN"]; end=ENVIRON["OMARCHY_END"]; block=ENVIRON["OMARCHY_BLOCK"] }
      $0 == begin { if (block != "") print block; skip=1; next }
      skip { if ($0 == end) skip=0; next }
      { print }
    ' "$target" >"$tmp"
    # A fresh block goes before user entries, which keep override priority.
    if [[ $action == install ]] && ! grep -Fqx -- "$BEGIN" "$target"; then
      OMARCHY_BLOCK="$payload" awk '
        { print; if (!inserted && $0 ~ /^[[:space:]]*\{[[:space:]]*$/) { print ENVIRON["OMARCHY_BLOCK"]; inserted=1 } }
      ' "$tmp" >"$tmp.insert"
      mv -- "$tmp.insert" "$tmp"
    fi
    chmod --reference="$target" "$tmp"
    cmp -s -- "$target" "$tmp" && return 0
  else
    printf '{\n%s\n}\n' "$(block)" >"$tmp"
    chmod 644 "$tmp"
  fi
  mv -- "$tmp" "$target"
}

case ${1:-install} in
  install)
    install_desktop
    menu_edit install
    refresh
    ;;
  clean)
    menu_edit remove
    rm -f -- "$DESKTOP"
    refresh
    ;;
  ifdisabled)
    # Fired from the plugin's teardown, which runs on disable AND on every
    # hot-reload. Only clean up when the plugin is really disabled — the
    # shell.json write has landed before the teardown begins.
    if grep -q -- "\"$ID\"" "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
      exit 0
    fi
    menu_edit remove
    rm -f -- "$DESKTOP"
    refresh
    ;;
  *)
    echo "usage: setup.sh install|clean|ifdisabled" >&2
    exit 2
    ;;
esac
