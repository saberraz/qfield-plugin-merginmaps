import QtQuick
import org.qfield

// Installs the plugin the way users do: QField's plugin manager, "Install plugin from URL", with the public
// release URL (also encoded in README's QR code). Run with NO_PLUGIN=1 so the plugin is not preinstalled.
// Needs internet access. Project plugins cannot read the environment, so run_e2e.sh substitutes INSTALL_URL (if set)
// for the URL below when it copies this file. CI uses the versioned zip, so the download count of the stable
// qfield-plugin-merginmaps.zip (README link and QR code) only counts real installs.
Item {
  id: t
  readonly property string url: "https://github.com/saberraz/qfield-plugin-merginmaps/releases/latest/download/qfield-plugin-merginmaps.zip"
  property int failures: 0
  property string installedUuid: ""
  function log(m) { console.warn("E2E " + m); }
  function check(c, what) { if (!c) failures++; log((c ? "PASS " : "FAIL ") + what); }
  function findVisualChild(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const f = findVisualChild(item.children[i], name);
      if (f) return f;
    }
    return null;
  }
  function finish() { log("RESULT failures=" + failures); log("DONE"); Qt.quit(); }

  Connections {
    target: pluginManager
    function onInstallTriggered(name) { t.log("installTriggered " + name); }
    function onInstallEnded(uuid, error) {
      t.log("installEnded uuid=" + uuid + " error=" + error);
      t.check(error === "" && uuid !== "", "installed from the release URL");
      t.check(uuid === "qfield-plugin-merginmaps", "plugin folder named after the zip: " + uuid);
      t.installedUuid = uuid;
      if (uuid !== "") pluginManager.enableAppPlugin(uuid);
      waitForButton.start();
    }
    function onPluginPermissionRequested(name, isProjectPlugin) {
      t.log("permission requested for " + name + " (project plugin: " + isProjectPlugin + ")");
      pluginManager.grantRequestedPluginPermission(true);
    }
  }

  Timer {
    id: waitForButton
    interval: 1000; repeat: true
    property int tries: 0
    onTriggered: {
      const button = t.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginPluginButton");
      if (button) {
        stop();
        t.check(pluginManager.isAppPluginEnabled(t.installedUuid), "plugin enabled");
        t.check(button.panel && button.panel.client.serverUrl === "https://app.merginmaps.com", "plugin running, default server app.merginmaps.com");
        t.log("SHOT i1_installed");
        Qt.callLater(function () { button.clicked(); });
        shotDelay.start();
      } else if (++tries > 30) {
        stop();
        t.check(false, "Mergin Maps toolbar button appeared");
        t.finish();
      }
    }
  }
  Timer { id: shotDelay; interval: 3000; onTriggered: { t.log("SHOT i2_panel"); quitDelay.start(); } }
  Timer { id: quitDelay; interval: 1500; onTriggered: t.finish() }

  Component.onCompleted: {
    log("installing " + url);
    pluginManager.installFromUrl(url);
  }
}
