import QtQuick
import org.qfield

// Login page (Mergin Maps mobile's MMLoginPage): hosted default server with "Sign up", "Change server" to the
// local Community Edition server (no self-registration, so no "Sign up"), then signing in through the form.
// Needs internet access for https://app.merginmaps.com/config. "Sign up" is not clicked: it opens a browser.
Item {
  id: d
  property var button: null
  property var panel: button ? button.panel : null
  property var client: panel ? panel.client : null
  property int step: 0
  property bool waiting: false
  property int failures: 0

  function log(m) { console.warn("E2E " + m); }
  function check(cond, what) { if (!cond) failures++; log((cond ? "PASS " : "FAIL ") + what); }
  function shot(name) { log("SHOT " + name); }
  function findVisible(item, name) {
    if (!item || !item.visible) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const found = findVisible(item.children[i], name);
      if (found) return found;
    }
    return null;
  }
  function item(name) {
    let root = iface.mainWindow().contentItem;
    while (root.parent) root = root.parent;
    return findVisible(root, name);
  }
  function tap(name) {
    const it = item(name);
    check(it !== null && it.enabled, "tap " + name);
    if (it) it.clicked();
  }

  Connections {
    target: d.client
    function onServerChecked(ok, message) { d.log("serverChecked " + ok + " " + message); d.waiting = false; }
    function onLoginFinished(ok, message) { d.log("loginFinished " + ok + " " + message); d.waiting = false; }
  }

  Timer {
    interval: 1500; repeat: true; running: d.button !== null
    onTriggered: {
      if (d.waiting) return;
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
    }
  }

  function tick() {
    switch (step) {
    case 0:
      iface.mainWindow().width = 420; iface.mainWindow().height = 760;
      check(client.serverUrl === "https://app.merginmaps.com", "default server " + client.serverUrl);
      waiting = true;
      panel.open();   // checks the server (/config)
      break;
    case 1:
      check(client.serverType === "saas" && client.serverSelfRegistration, "hosted server: saas with self-registration (" + client.serverType + ")");
      check(client.signUpUrl === "https://app.merginmaps.com/register", "sign-up URL " + client.signUpUrl);
      check(item("merginSignUpButton") !== null, "Sign up button shown");
      check(item("merginForgotPasswordButton") !== null, "Forgot password shown");
      check(item("merginServerButton").text === "https://app.merginmaps.com", "server shown in the footer");
      shot("l1_login_hosted");
      break;
    case 2:
      tap("merginServerButton");
      break;
    case 3:
      check(item("merginServerField") !== null, "Change server drawer open");
      item("merginServerField").text = "http://127.0.0.1:5000";
      shot("l2_change_server");
      break;
    case 4:
      waiting = true;
      tap("merginServerConfirm");
      break;
    case 5:
      check(client.serverUrl === "http://127.0.0.1:5000" && client.serverType === "ce", "CE server checked (" + client.serverType + ")");
      check(client.signUpUrl === "" && item("merginSignUpButton") === null, "no Sign up on Community Edition");
      item("merginLoginField").text = "fielduser";
      item("merginPasswordField").text = "Field-Pass-123";
      shot("l3_login_ce");
      break;
    case 6:
      waiting = true;
      tap("merginLoginButton");
      break;
    case 7:
      check(client.loggedIn && client.username === "fielduser", "signed in through the form");
      shot("l4_signed_in");
      log("RESULT failures=" + failures);
      log("DONE");
      Qt.quit();
      break;
    }
    step++;
  }
}
