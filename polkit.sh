#!/bin/sh
# Polkit whitelist helper for the Services Hub plugin.
#
#   sync <candidate-file>   install the generated rules (run as root via pkexec)
#   remove                  remove our rules file if it is ours (pkexec)
#   status                  report presence + signature (no root; user read)
#
# The rules file covers exactly two polkit actions for the units listed in
# the generated whitelist:
#   org.freedesktop.systemd1.manage-units      (detail "unit")     start/stop/restart
#   org.freedesktop.systemd1.manage-unit-files (detail "unitfile") enable/disable
# Anything else keeps the system's default polkit policy.

RULES=/etc/polkit-1/rules.d/49-services-hub.rules
MARKER="managed-by=geryruslandi.services-hub"

ours() {
  [ -f "$RULES" ] && grep -q "$MARKER" "$RULES"
}

case $1 in
  sync)
    candidate=$2
    [ -n "$candidate" ] && [ -f "$candidate" ] || exit 2
    grep -q "$MARKER" "$candidate" || { echo "not a Services Hub rules file" >&2; exit 3; }
    mkdir -p "$(dirname "$RULES")"
    tmp=$(mktemp "$(dirname "$RULES")/.services-hub.XXXXXX")
    cat "$candidate" >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$RULES"
    echo ok
    ;;
  remove)
    if [ -f "$RULES" ]; then
      if ours; then
        rm -f "$RULES"
        echo ok
      else
        echo "not ours; leaving it alone" >&2
        exit 3
      fi
    else
      echo ok
    fi
    ;;
  status)
    # No root needed when the rules are readable; on systems where rules.d is
    # root-only (750), existence cannot be checked as the invoking user —
    # report "unreadable" and let the panel trust its own sync record.
    if [ -d /etc/polkit-1/rules.d ]; then
      err=$(ls /etc/polkit-1/rules.d 2>&1 >/dev/null)
      case $err in
        *denied*)
          echo unreadable
          exit 0
          ;;
      esac
    fi
    if [ -f "$RULES" ] && [ -r "$RULES" ]; then
      sig=$(sed -n "s/^.*${MARKER} signature=\([0-9a-f]*\).*\$/\1/p" "$RULES" | head -n1)
      echo "present ${sig:-unknown}"
    elif [ -f "$RULES" ]; then
      echo present
    else
      echo absent
    fi
    ;;
  *)
    echo "usage: polkit.sh sync <candidate>|remove|status" >&2
    exit 2
    ;;
esac
