import QtQuick
import org.qfield

// Test-only app plugin: drives the Mergin plugin through a two-user sync scenario (see ../server_actions.py).
Item {
  id: d
  property var button: null
  property var panel: null
  property var client: null
  property var projects: null
  property var sync: null
  property string signals: ""
  property int step: 0
  property bool waiting: false
  property string waitSignal: ""
  property int failures: 0
  property var lastSync: null

  function log(m) { console.warn("E2E " + m); }
  function check(cond, what) { if (!cond) failures++; log((cond ? "PASS " : "FAIL ") + what); }
  function findVisualChild(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) { const f = findVisualChild(item.children[i], name); if (f) return f; }
    return null;
  }
  function trees() {
    const layers = QfProjectUtils.mapLayers(qgisProject);
    for (const k in layers) if (layers[k].name === "Trees") return layers[k];
    return null;
  }
  function server(action) { waitSignal = signals + action + ".done"; log("SERVER " + action); }

  Connections {
    target: d.sync
    function onSyncFinished(ok, message) { d.lastSync = { ok: ok, message: message }; d.log("syncFinished " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.projects
    function onDownloadFinished(ok, fullName, message) { d.log("downloadFinished " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.client
    function onLoginFinished(ok, message) { d.waiting = false; }
  }

  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: {
      if (!d.button) {
        const b = d.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginPluginButton");
        if (!b || !qgisProject.fileName) return;
        d.button = b; d.panel = b.panel; d.client = d.panel.client; d.projects = d.panel.projects; d.sync = b.syncEngine;
        d.signals = qgisProject.homePath + "/signals/";
        return;
      }
      if (d.waiting || d.projects.listing) return;
      if (d.waitSignal !== "") { if (!QfFileUtils.fileExists(d.waitSignal)) return; d.waitSignal = ""; }
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
    }
  }

  function edit(fn) {
    const l = trees();
    check(l.startEditing(), "startEditing");
    fn(l);
    check(l.commitChanges(), "commitChanges");
  }
  function setAttr(l, fid, field, value) { check(l.changeAttributeValue(fid, l.fields.indexOf(field), value), "set " + field + " of tree " + fid); }

  function tick() {
    switch (step) {
    case 0:
      iface.mainWindow().width = 540; iface.mainWindow().height = 960;
      client.setServerUrl("http://127.0.0.1:5000");
      waiting = true; client.login("fielduser", "Field-Pass-123", false);
      break;
    case 1:
      waiting = true; projects.download("mergin", "dummy-points");
      break;
    case 2:
      check(sync.currentFullName === "mergin/dummy-points", "open project recognised as Mergin project: " + sync.currentFullName);
      // --- scenario 1: field edits + a new photo, then sync (push only)
      edit(function (l) {
        setAttr(l, 1, "species", "Field Ash");
        check(l.deleteFeature(2), "delete tree 2");
        const f = QfFeatureUtils.createFeature(l, QfGeometryUtils.createGeometryFromWkt("POINT (-0.1420 50.8226)"));
        f.setAttribute("species", "Field tree"); f.setAttribute("height_m", 4.2); f.setAttribute("surveyor", "fielduser");
        check(QfLayerUtils.addFeature(l, f), "add tree");
      });
      const photo = new Uint8Array(20000); for (let i = 0; i < photo.length; i++) photo[i] = (i * 31 + 7) & 255;
      check(QfFileUtils.writeFileContent(qgisProject.homePath + "/DCIM/field_photo.jpg", photo.buffer), "photo written");
      waiting = true; log("SHOT s1_before_sync"); sync.syncCurrent();
      break;
    case 3:
      check(lastSync.ok && lastSync.message === "Successfully synchronised", "scenario 1 sync: " + lastSync.message);
      // --- scenario 2: office edits on the server while QField edits another tree -> pull + rebase + push
      server("office_edit");
      break;
    case 4:
      edit(function (l) { setAttr(l, 4, "species", "Field Beech"); });
      waiting = true; sync.syncCurrent();
      break;
    case 5:
      check(lastSync.ok, "scenario 2 sync (rebase): " + lastSync.message);
      check(QfFileUtils.fileExists(qgisProject.homePath + "/notes/office.txt"), "office file pulled");
      check(trees().getFeature(3).attribute("species") === "Office Oak", "office edit visible in QField after reload");
      check(trees().getFeature(4).attribute("species") === "Field Beech", "own edit survived the rebase");
      // --- scenario 3: both edit the height of tree 5 -> conflict
      server("office_conflict");
      break;
    case 6:
      edit(function (l) { setAttr(l, 5, "height_m", 11.0); });
      waiting = true; sync.syncCurrent();
      break;
    case 7:
      check(lastSync.ok, "scenario 3 sync (conflict): " + lastSync.message);
      log("tree 5 height in QField after conflict: " + trees().getFeature(5).attribute("height_m"));
      // --- scenario 4: nothing to do
      waiting = true; sync.syncCurrent();
      break;
    case 8:
      check(lastSync.ok && lastSync.message === "Up to date", "scenario 4: " + lastSync.message);
      log("SHOT s4_synced");
      // --- scenario 5: edit, server goes down, sync must fail without losing the edit
      edit(function (l) { setAttr(l, 6, "species", "Offline Yew"); });
      server("stop_server");
      break;
    case 9:
      waiting = true; sync.syncCurrent();
      break;
    case 10:
      check(!lastSync.ok, "scenario 5: sync fails while the server is down: " + lastSync.message);
      check(trees().getFeature(6).attribute("species") === "Offline Yew", "local edit intact after the failed sync");
      server("start_server");
      break;
    case 11:
      waiting = true; sync.syncCurrent();
      break;
    case 12:
      check(lastSync.ok && lastSync.message === "Successfully synchronised", "scenario 5: sync after the server is back: " + lastSync.message);
      // --- scenario 6: the office deletes a file; QField cannot delete it, but must not push it back
      server("office_remove");
      break;
    case 13:
      waiting = true; sync.syncCurrent();
      break;
    case 14:
      check(lastSync.ok, "scenario 6 sync (server removal): " + lastSync.message);
      waiting = true; sync.syncCurrent();
      break;
    case 15:
      check(lastSync.ok && lastSync.message === "Up to date", "scenario 6: removed file not pushed back: " + lastSync.message);
      log("RESULT failures=" + failures);
      log("DONE"); Qt.quit();
      break;
    }
    step++;
  }
}
