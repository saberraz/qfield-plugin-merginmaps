import QtQuick
import org.qfield

// Screenshots for docs and announcements (not a test). Run on a 1080x2160 display with QT_SCALE_FACTOR=2:
//   QT_SCALE_FACTOR=2 E2E_TIMEOUT=300 tests/qfield/run_e2e.sh promo_shots
// Uses the local CE server (bee-farming project; server_actions.py pauses it briefly so the sync banner can be
// captured) and the mock multi-workspace server (port 5055). Each run pushes a new version of bee-farming.
// Each SHOT is logged in its own step, before the next action (the capture happens ~0.5 s later).
Item {
  id: d
  property var button: null
  property var panel: button ? button.panel : null
  property var client: panel ? panel.client : null
  property var projects: panel ? panel.projects : null
  property var sync: button ? button.syncEngine : null
  property int step: 0
  property bool waiting: false
  property int pause: 0

  function log(m) { console.warn("E2E " + m); }
  function shot(name) { log("SHOT " + name); }
  function findVisible(item, name) {
    if (!item || !item.visible) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const f = findVisible(item.children[i], name);
      if (f) return f;
    }
    return null;
  }
  function item(name) {
    let root = iface.mainWindow().contentItem;
    while (root.parent) root = root.parent;
    return findVisible(root, name);
  }
  function findLayer(name) {   // not "layer": that is an Item property
    const layers = QfProjectUtils.mapLayers(qgisProject);
    for (const k in layers) if (layers[k].name === name) return layers[k];
    return null;
  }

  Connections {
    target: d.client
    function onServerChecked(ok, message) { d.waiting = false; }
    function onLoginFinished(ok, message) { d.log("login " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.projects
    function onDownloadFinished(ok, fullName, message) { d.log("download " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.sync
    function onSyncFinished(ok, message) { d.log("sync " + ok + " " + message); d.waiting = false; }
  }

  Timer {
    interval: 1000; repeat: true; running: d.button !== null
    onTriggered: {
      if (d.pause > 0) { d.pause--; return; }
      if (d.waiting || d.projects.listing) return;
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
    }
  }

  function tick() {
    switch (step) {
    case 0:
      iface.mainWindow().width = 540; iface.mainWindow().height = 1080;
      waiting = true;
      panel.open();                        // default server app.merginmaps.com: login page with "Sign up"
      break;
    case 1:
      item("merginLoginField").text = "surveyor@example.com";
      item("merginPasswordField").text = "correct-horse-battery";
      pause = 1;
      break;
    case 2:
      shot("01_login");
      break;
    case 3:
      client.setServerUrl("http://127.0.0.1:5000");
      waiting = true;
      client.login("fielduser", "Field-Pass-123", false);
      break;
    case 4:
      pause = 1;
      break;
    case 5:
      shot("02_projects");
      break;
    case 6:
      waiting = true;
      projects.download("mergin", "bee-farming");
      break;
    case 7:
      pause = 4;                           // let the map render
      break;
    case 8:
      shot("03_map");
      break;
    case 9: {
      // field edits: update an apiary, add a new one next to it
      const l = findLayer("Apiary");
      log("layer " + (l ? l.name : "missing"));
      l.startEditing();
      l.changeAttributeValue(2, l.fields.indexOf("nbr_of_boxes"), 12);
      const f = QfFeatureUtils.createFeature(l, QfGeometryUtils.createGeometryFromWkt("POINT (1030655 5911185)"));
      f.setAttribute("beekeeper", "Field team");
      f.setAttribute("nbr_of_boxes", 5);
      f.setAttribute("bee_species", "Apis Mellifera Carnica");
      QfLayerUtils.addFeature(l, f);
      l.commitChanges();
      pause = 4;                           // QField flushes the edit into the GeoPackage
      break;
    }
    case 10:
      log("SERVER pause");                 // the sync then waits on the server: the banner stays up
      waiting = true;
      Qt.callLater(function () { sync.syncCurrent(); });
      syncShot.start();
      break;
    case 11:
      shot("05_synced");                   // toast "Successfully synchronised"
      pause = 3;
      break;
    case 12:
      panel.open();
      panel.showPage("home");
      pause = 1;
      break;
    case 13:
      shot("06_home");
      break;
    case 14: {
      const more = item("merginHomeMore_bee-farming");   // shot next step
      if (more) more.clicked();
      pause = 1;
      break;
    }
    case 15:
      shot("07_more_options");
      break;
    case 16: {
      const close = item("merginMoreOptionsClose");
      if (close) close.clicked();
      panel.close();
      client.logout();
      panel.workspaces.clear();
      client.setServerUrl("http://127.0.0.1:5055");
      waiting = true;
      client.login("sarah", "Sarah-Pass-123", false);
      break;
    }
    case 17:
      panel.open();
      pause = 2;
      break;
    case 18:
      panel.showPage("workspaces");
      pause = 3;                           // give QField time to repaint after the sign-in switch
      break;
    case 19:
      shot("08_workspaces");
      break;
    case 20:
      panel.showPage("projects");
      pause = 1;
      break;
    case 21:
      shot("09_my_team");
      pause = 1;
      break;
    case 22:
      log("DONE");
      Qt.quit();
      break;
    }
    step++;
  }

  // the sync banner is visible while syncing: capture it shortly after the start
  Timer { id: syncShot; interval: 2500; onTriggered: { d.shot("04_syncing"); unpause.start(); } }
  Timer { id: unpause; interval: 2500; onTriggered: d.log("SERVER unpause") }
}
