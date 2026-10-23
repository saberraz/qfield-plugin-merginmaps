import QtQuick
import org.qfield

// Position tracking on a Mergin tracking layer with QField's own tracking UI, synced while tracking (twice, the first
// time right after a colleague uploaded a track with the same new feature id), then stopped and synced again.
// Positions come from tests/qfield/nmea_server.py (see needs_gnss); server side: ../server_actions.py.
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
  property string waitSignal: ""
  property string signalsDir: ""
  property var lastSync: null
  property var trkLayer: null
  property int failures: 0
  property int verticesAtSync: 0
  property bool inTick: false

  function log(m) { console.warn("E2E " + m); }
  function check(c, what) { if (!c) failures++; log((c ? "PASS " : "FAIL ") + what); }
  function server(action) { waitSignal = signalsDir + action + ".done"; log("SERVER " + action); }
  function walk(item, fn) {
    if (!item) return null;
    const r = fn(item);
    if (r) return r;
    for (let i = 0; i < item.children.length; i++) { const f = walk(item.children[i], fn); if (f) return f; }
    return null;
  }
  function root() { let r = iface.mainWindow().contentItem; while (r.parent) r = r.parent; return r; }
  function findLayer(name) { const ls = QfProjectUtils.mapLayers(qgisProject); for (const k in ls) if (ls[k].name === name) return ls[k]; return null; }
  function tracker() { return trkLayer ? trackingModel.trackerForLayer(trkLayer) : null; }
  function pos() { return iface.findItemByObjectName("positionSource"); }

  Connections {
    target: d.client
    function onLoginFinished(ok, message) { d.log("login " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.projects
    function onDownloadFinished(ok, fullName, message) { d.log("download " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.sync
    function onSyncFinished(ok, message) { d.lastSync = { ok: ok, message: message }; d.log("sync " + ok + " " + message); d.waiting = false; }
  }

  Timer {
    interval: 1000; repeat: true; running: d.button !== null
    onTriggered: {
      if (d.pause > 0) { d.pause--; return; }
      if (d.waiting) return;
      if (d.waitSignal !== "") { if (!QfFileUtils.fileExists(d.waitSignal)) return; d.waitSignal = ""; }
      if (d.inTick) return;    // opening QField dialogs can process events (and fire this timer) re-entrantly
      d.inTick = true;
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
      d.inTick = false;
    }
  }

  function tick() {
    switch (step) {
    case 0:
      signalsDir = qgisProject.homePath + "/signals/";
      iface.mainWindow().width = 540; iface.mainWindow().height = 960;
      server("setup");
      break;
    case 1:
      client.setServerUrl("http://127.0.0.1:5000");
      waiting = true;
      client.login("fielduser", "Field-Pass-123", false);
      break;
    case 2:
      waiting = true;
      projects.download("mergin", "tracking-e2e");
      break;
    case 3: {
      check(sync.currentFullName === "mergin/tracking-e2e", "tracking project open: " + sync.currentFullName);
      const vars = QfExpressionContextUtils.projectVariables(qgisProject);
      check(vars.mm_username === "fielduser" && vars.mergin_username === "fielduser", "@mm_username / @mergin_username set: " + vars.mm_username);
      check(vars.mm_project_full_name === "mergin/tracking-e2e", "@mm_project_full_name = " + vars.mm_project_full_name);
      trkLayer = findLayer("tracking_layer");
      check(trkLayer !== null, "tracking layer in the project");
      break;
    }
    case 4:
      if (!pos().positionInformation.latitudeValid) { step--; break; }   // wait for the simulated receiver
      log("position " + pos().positionInformation.latitude + " " + pos().positionInformation.longitude);
      break;
    case 5: {
      // QField's own Tracking dialog, as from the location button
      const ts = iface.findItemByObjectName("trackerSettings");
      ts.prepareSettings();
      ts.open();
      check(ts.layer && ts.layer.name === "tracking_layer", "QField's Tracking dialog pre-selects the Mergin tracking layer");
      break;
    }
    case 6: {
      const ts = iface.findItemByObjectName("trackerSettings");
      const start = walk(ts.contentItem, function (it) { return it.text === "Start tracking" && it.clicked ? it : null; });
      start.clicked();
      pause = 1;
      break;
    }
    case 7: {
      // QField's tracking form: confirm it (the form's ✓)
      const form = walk(root(), function (it) { return it.visible && it.setupOnly === true && typeof it.confirm === "function" ? it : null; });
      check(form !== null, "QField shows the tracking form");
      log("SHOT k1_form");
      break;
    }
    case 8: {
      const form = walk(root(), function (it) { return it.visible && it.setupOnly === true && typeof it.confirm === "function" ? it : null; });
      form.confirm();
      pause = 1;
      break;
    }
    case 9: {
      const tr = tracker();
      check(tr && tr.isActive, "tracking started");
      check(tr.feature.attribute("tracked_by") === "fielduser", "form pre-filled tracked_by from @mm_username: " + tr.feature.attribute("tracked_by"));
      check(tr.feature.attribute("tracking_start_time") !== undefined, "form pre-filled tracking_start_time: " + tr.feature.attribute("tracking_start_time"));
      pause = 8;   // the feature is created at the 3rd point
      break;
    }
    case 10: {
      const tr = tracker();
      check(tr.feature.id >= 0, "track feature created: " + tr.feature.id);
      const ms = new Date(tr.startPositionTimestamp).getTime();
      if (ms > 0) log("INFO first_point_ms=" + ms);
      server("office_track");   // a colleague's track takes the same new feature id on the server
      break;
    }
    case 11:
      verticesAtSync = tracker().rubberbandModel.vertexCount;
      waiting = true;
      sync.syncCurrent();       // sync #1 while tracking: pull (rebase renumbers our track), push
      break;
    case 12: {
      check(lastSync.ok, "sync #1 during tracking: " + lastSync.message);
      trkLayer = findLayer("tracking_layer");
      const tr = tracker();
      check(tr && tr.isActive, "tracking still active after the sync");
      check(tr && tr.feature.attribute("tracked_by") === "fielduser", "tracker continues on our track (feature " + (tr ? tr.feature.id : "-") + ")");
      check(tr && tr.rubberbandModel.vertexCount >= verticesAtSync, "the line kept its points: " + verticesAtSync + " -> " + (tr ? tr.rubberbandModel.vertexCount : 0));
      server("check_partial");
      break;
    }
    case 13:
      pause = 10;
      break;
    case 14:
      waiting = true;
      sync.syncCurrent();       // sync #2 while tracking
      break;
    case 15: {
      check(lastSync.ok, "sync #2 during tracking: " + lastSync.message);
      trkLayer = findLayer("tracking_layer");
      check(tracker() && tracker().isActive, "tracking still active after sync #2");
      pause = 6;
      break;
    }
    case 16: {
      const fid = tracker().feature.id;
      trackingModel.stopTracker(trkLayer);
      const f = trkLayer.getFeature(fid);
      check(f.attribute("tracking_end_time") !== undefined && f.attribute("total_distance") !== undefined,
            "stop completed end time and distance: " + f.attribute("tracking_end_time") + ", " + f.attribute("total_distance"));
      log("SHOT k2_stopped");
      break;
    }
    case 17:
      waiting = true;
      sync.syncCurrent();       // final sync
      break;
    case 18:
      check(lastSync.ok, "final sync: " + lastSync.message);
      log("RESULT failures=" + failures);
      log("DONE");
      Qt.quit();
      break;
    }
    step++;
  }
}
