#!/bin/sh
# Scope-aware port of memory.sh from MIT-licensed
# gabepsilva/omarchy-user-services. Print "<unit>=<bytes>" for every service
# of the given scope, where bytes is the RAM the service itself holds:
# anonymous memory + shmem + kernel memory from its cgroup's memory.stat.
# Page cache (e.g. model weights read from disk) is left out; the kernel
# drops it whenever something else needs the memory.
# With a unit name as the second argument, only that unit is reported.
#
#   memory.sh user|system [unit]
#
# Both scopes work unprivileged: system cgroups under
# /sys/fs/cgroup/system.slice are world-readable.

scope=${1:-user}
unit=$2

case $scope in
  user) SCTL="systemctl --user" ;;
  system) SCTL="systemctl" ;;
  *) exit 2 ;;
esac

$SCTL show -p Id,ControlGroup --no-pager -- "${unit:-*.service}" | awk -F= '
  function flush() {
    if (id != "" && cg != "") {
      f = "/sys/fs/cgroup" cg "/memory.stat"
      used = 0
      while ((getline line < f) > 0) {
        split(line, p, " ")
        if (p[1] == "anon" || p[1] == "shmem" || p[1] == "kernel") used += p[2]
      }
      close(f)
      if (used > 0) print id "=" used
    }
    id = ""; cg = ""
  }
  /^Id=/           { id = substr($0, 4) }
  /^ControlGroup=/ { cg = substr($0, 14) }
  /^$/             { flush() }
  END              { flush() }
'
