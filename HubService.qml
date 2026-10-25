import QtQuick
import Quickshell
import "Model.js" as Model

// Non-visual service half of the Services Hub plugin (declared as
// kind "service" beside the overlay entry point).
//
// Service items load at shell startup (unlike the panel, which only loads
// while summoned), so this surface owns the launcher-entry/menu-row
// install. It also sees teardowns: disable, shell shutdown, and hot-reloads
// — all of them funnel into guarded script modes that answer the "am I
// enabled?" question against shell.json themselves, so a teardown that is
// really just a reload leaves the artifacts alone.

Item {
  id: root

  property var pluginRegistry: null

  // Boot-time and reload-time: make sure the launcher entry + menu block
  // exist and match the shipped templates. Idempotent.
  Component.onCompleted: {
    Quickshell.execDetached(["bash", resolve("setup.sh"), "install"])
  }

  // When the (short-lived) registry view flips — including the startup
  // moment where it reports false before shell.json has loaded — re-check
  // through the guarded mode; only a genuine disable cleans up.
  readonly property bool pluginEnabled: pluginRegistry ? pluginRegistry.enabled === true : false
  onPluginEnabledChanged: {
    Quickshell.execDetached(["bash", resolve("setup.sh"), "ifdisabled"])
  }

  // Teardown: disable, shutdown, hot-reload — same guarded check.
  Component.onDestruction: {
    Quickshell.execDetached(["bash", resolve("setup.sh"), "ifdisabled"])
  }

  function resolve(name) {
    return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")
  }
}
