import QtQuick
import org.qfield

// Lives under the plugin's toolbar button, so it keeps running while projects are switched.
Item {
  id: d
  property var button: null
  property var panel: button ? button.panel : null
  property var client: panel ? panel.client : null
  property var projects: panel ? panel.projects : null
  property int step: 0
  property bool waiting: false
  property var queue: ["dummy-points", "dummy-edge-cases", "bee-farming", "wastewater-network"]
  property int failures: 0

  function log(m) { console.warn("E2E " + m); }
  function check(cond, what) { if (!cond) failures++; log((cond ? "PASS " : "FAIL ") + what); }
  function shot(name) { log("SHOT " + name); }

  Connections {
    target: d.client
    function onLoginFinished(ok, message) { d.log("loginFinished " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.projects
    function onDownloadFinished(ok, fullName, message) { d.log("downloadFinished " + ok + " " + fullName + " " + message); d.lastOk = ok; d.waiting = false; }
  }
  property bool lastOk: false

  Timer {
    interval: 1500; repeat: true; running: d.button !== null
    onTriggered: {
      if (d.waiting || d.projects.listing) return;
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
    }
  }

  function verifyDownloaded(name) {
    const dir = projects.localDir("mergin", name);
    check(qgisProject.fileName.indexOf(dir + "/") === 0, name + ": opened project " + qgisProject.fileName.split("/").slice(-3).join("/"));
    check(QfFileUtils.fileExists(dir + "/.mergin/mergin.json"), name + ": mergin.json written");
    const layers = QfProjectUtils.mapLayers(qgisProject);
    const names = Object.keys(layers).map(function (k) { return layers[k].name; });
    check(names.length > 0, name + ": layers loaded " + JSON.stringify(names));
    const invalid = Object.keys(layers).filter(function (k) { return !layers[k].isValid; }).map(function (k) { return layers[k].name; });
    check(invalid.length === 0, name + ": all layers valid " + JSON.stringify(invalid));
  }

  function tick() {
    if (step === 0) {
      iface.mainWindow().width = 420; iface.mainWindow().height = 760;
      client.setServerUrl("http://127.0.0.1:5000");
      panel.open();
      waiting = true;
      client.login("fielduser", "Field-Pass-123", false);
    } else if (step === 1) {
      const names = projects.remoteProjects.map(function (p) { return p.namespace + "/" + p.name; });
      check(names.length === 4, "listed " + JSON.stringify(names));
      shot("p1_project_list");
    } else if (step >= 2 && step < 2 + queue.length * 2) {
      const i = Math.floor((step - 2) / 2);
      const name = queue[i];
      if ((step - 2) % 2 === 0) {
        if (i > 0) panel.open();
        waiting = true;
        log("downloading " + name);
        projects.download("mergin", name);
      } else {
        check(lastOk, name + ": download ok");
        verifyDownloaded(name);
        shot("p" + (i + 2) + "_opened_" + name);
      }
    } else if (step === 2 + queue.length * 2) {
      const e = projects.localDir("mergin", "dummy-edge-cases");
      check(QfFileUtils.fileExists(e + "/Fotky ščé/photo 1.jpg"), "unicode path written");
      check(QfFileUtils.fileExists(e + "/data/trees & shrubs (2026).gpkg"), "path with & and () written");
      check(QfFileUtils.fileExists(e + "/.mergin/big/points_big.gpkg"), "base copy of chunked GeoPackage");
      check(!QfFileUtils.fileExists(e + "/.mergin/README.txt"), "no base copy for non-GeoPackage files");
      panel.open();
      projects.refresh();
    } else if (step === 3 + queue.length * 2) {
      check(projects.remoteProjects.every(function (p) { return p.downloaded; }), "all marked on this device");
      shot("p6_list_downloaded");
      waiting = false;
      panel.close();
      projects.openLocal("mergin", "dummy-points");
    } else if (step === 4 + queue.length * 2) {
      check(qgisProject.fileName === projects.localDir("mergin", "dummy-points") + "/dummy-points.qgs", "re-opened dummy-points from the list: " + qgisProject.fileName.split("/").slice(-2).join("/"));
      log("RESULT failures=" + failures);
      log("HOME " + projects.homeDir());
      log("DONE");
      Qt.quit();
    }
    step++;
  }
}
