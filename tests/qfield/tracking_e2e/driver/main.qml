import QtQuick
import org.qfield

// Test-only app plugin: waits for the Mergin plugin, then runs Driver.qml (app plugins survive project switches).
Item {
  id: t
  function findVisualChild(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const found = findVisualChild(item.children[i], name);
      if (found) return found;
    }
    return null;
  }
  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: {
      const button = t.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginPluginButton");
      if (!button) { console.warn("E2E waiting for plugin"); return; }
      running = false;
      driver.button = button;
      driver.active = true;
    }
  }
  Driver { id: driver; property bool active: false; enabled: active }
}
