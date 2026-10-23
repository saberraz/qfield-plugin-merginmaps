import QtQuick
import org.qfield

// End-to-end check of the installed Mergin plugin inside QField: drives the live MerginPanel/MerginClient
// (real iface.createHttpRequest and settings) against the local test server and saves screenshots.
Item {
  id: t
  property var panel: null
  property var client: null
  property int step: 0
  property string shots: qgisProject.homePath + "/screenshots/"
  property bool waiting: false

  // Plugin items are only visually reparented into QField's UI, so search the visual tree, not QObject children.
  function findVisualChild(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const found = findVisualChild(item.children[i], name);
      if (found) return found;
    }
    return null;
  }

  function log(m) { console.warn("E2E " + m); }
  // Screenshots are taken from outside by run_e2e.sh when it sees this line (grabToImage is refused on this window).
  function shot(name) {
    log("SHOT " + name);
  }

  Connections {
    target: t.client
    function onLoginFinished(ok, message) { t.log("loginFinished ok=" + ok + " message=" + message); t.waiting = false; }
    function onServerChecked(ok, message) { t.log("serverChecked ok=" + ok + " message=" + message); }
  }

  Timer {
    interval: 1500; repeat: true; running: true
    onTriggered: {
      if (t.waiting) return;
      try { t.tick(); } catch (e) { t.log("EXCEPTION at step " + t.step + ": " + e); Qt.quit(); }
    }
  }

  function tick() {
    if (step === 0) {
      const button = t.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginPluginButton");
      if (!button) { log("waiting for plugin"); return; }
      panel = button.panel;
      client = panel.client;
      log("found plugin; initial state loggedIn=" + client.loggedIn + " server=" + client.serverUrl);
      iface.mainWindow().width = 420; iface.mainWindow().height = 760;   // phone-like
      client.setServerUrl("http://127.0.0.1:5000");
      panel.open();
    } else if (step === 1) {
      shot("1_signed_out");
      log("server version=" + client.serverVersion + " reachable=" + client.serverReachable);
    } else if (step === 2) {
      waiting = true;
      client.login("fielduser", "wrong-password", false);
    } else if (step === 3) {
      shot("2_wrong_password");
    } else if (step === 4) {
      waiting = true;
      client.login("fielduser", "Field-Pass-123", true);
    } else if (step === 5) {
      shot("3_signed_in");
      log("loggedIn=" + client.loggedIn + " username=" + client.username + " email=" + client.email + " expiry=" + client.tokenExpiry);
      log("persisted username=" + settings.value("qfield-mergin/username", "") + " remember=" + settings.valueBool("qfield-mergin/rememberPassword", false) + " passwordStored=" + (settings.value("qfield-mergin/password", "") !== ""));
    } else if (step === 6) {
      client.tokenExpiry = "2000-01-01T00:00:00Z";
      waiting = true;
      client.authRequest("GET", "v1/user/profile", undefined, function (r) { t.log("authRequest after forced expiry OK, profile username=" + r.username + ", new expiry=" + t.client.tokenExpiry); t.waiting = false; },
                         function (m, s) { t.log("authRequest FAILED " + s + " " + m); t.waiting = false; });
    } else if (step === 7) {
      client.logout();
      log("after logout loggedIn=" + client.loggedIn + " passwordStored=" + (settings.value("qfield-mergin/password", "") !== ""));
    } else if (step === 8) {
      shot("4_logged_out");
    } else if (step === 9) {
      log("DONE"); Qt.quit();
    }
    step++;
  }
}
