import QtQuick
import QtQuick.Controls
import org.qfield

// Test-only app plugin: screencast of the two-way sync workflow, operating the real Mergin plugin UI at human pace:
// a touch indicator shows each tap, captions explain each step. Every action goes through the actual controls.
Item {
  id: demo

  property var pluginButton: null
  property var panel: null
  property var steps: []
  // QQuickOverlay (where popups live), so captions and the touch marker are drawn above the Mergin panel.
  property var overlay: null
  // An open popup's item is parented to the window's QQuickOverlay: walk up from the panel's content to find it.
  function findOverlay() {
    let it = panel && panel.opened ? panel.contentItem : null;
    while (it && String(it).indexOf("QQuickOverlay") !== 0) it = it.parent;
    return it || iface.mainWindow().contentItem;
  }
  function liftOverlayItems() {
    const target = findOverlay();
    if (overlay !== target) { overlay = target; caption.parent = target; touch.parent = target; }
  }
  property int stepIndex: 0

  function log(m) { console.warn("DEMO " + m); }

  function findVisualChild(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    const kids = item.children || [];
    for (let i = 0; i < kids.length; i++) {
      const found = findVisualChild(kids[i], name);
      if (found) return found;
    }
    // Popup / ListView content lives below contentItem / contentItem.children
    if (item.contentItem && item.contentItem !== item) return findVisualChild(item.contentItem, name);
    return null;
  }
  function panelItem(name) { return findVisualChild(panel.contentItem, name); }

  // ---- overlay: caption + touch indicator (above popups) ----
  Rectangle {
    id: caption
    parent: demo.overlay
    z: 10000
    visible: captionText.text !== ""
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    y: parent ? parent.height - height - 12 : 0   // below QField's toasts
    width: Math.min(parent ? parent.width - 32 : 300, 500)
    height: captionText.implicitHeight + 20
    radius: 10
    color: "#E6203038"
    Text {
      id: captionText
      anchors.fill: parent
      anchors.margins: 10
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      color: "white"
      font.pixelSize: 17
      font.bold: true
    }
  }

  Rectangle {
    id: touch
    parent: demo.overlay
    z: 10001
    width: 44; height: 44; radius: 22
    color: "#5590EE90"
    border.color: "#2E7D32"; border.width: 3
    visible: false
    Behavior on x { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }
    Behavior on y { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }
    SequentialAnimation on scale { id: pulse; running: false; NumberAnimation { to: 0.7; duration: 120 } NumberAnimation { to: 1.0; duration: 160 } }
  }

  function pointAt(item) {
    liftOverlayItems();
    const p = item.mapToItem(demo.overlay, item.width / 2, item.height / 2);
    if (!touch.visible) { touch.x = p.x - 22; touch.y = p.y - 22; touch.visible = true; }
    touch.x = p.x - 22; touch.y = p.y - 22;
  }

  // ---- step script ----
  // each step: { wait: ms before running, run: fn } or { until: fn returning bool, timeout: ms }
  function say(text) { return { wait: 200, run: function () { demo.liftOverlayItems(); captionText.text = text; } }; }
  function pause(ms) { return { wait: ms, run: function () {} }; }
  function tap(getItem) {
    return [{ wait: 300, run: function () { const it = getItem(); if (it) demo.pointAt(it); } },
            { wait: 650, run: function () { const it = getItem(); pulse.restart(); if (it) it.clicked(); else demo.log("tap target missing"); } }];
  }
  function type(getItem, text) {
    const out = [{ wait: 300, run: function () { const f = getItem(); demo.pointAt(f); f.forceActiveFocus(); f.text = ""; } }];
    for (let i = 1; i <= text.length; i++) {
      const partial = text.substring(0, i);
      out.push({ wait: 70, run: function () { getItem().text = partial; } });
    }
    return out;
  }
  function waitUntil(cond, timeout) { return { until: cond, timeout: timeout || 30000 }; }
  function projectButton(name) { return function () { return demo.panelItem("merginProjectButton_" + name); }; }

  property string signals: ""
  function server(action) {
    return [{ wait: 100, run: function () { demo.log("E2E SERVER " + action); console.warn("E2E SERVER " + action); } },
            waitUntil(function () { return QfFileUtils.fileExists(demo.signals + action + ".done"); }, 60000)];
  }
  function treesLayer() {
    const layers = QfProjectUtils.mapLayers(qgisProject);
    for (const k in layers) if (layers[k].name === "Trees") return layers[k];
    return null;
  }

  function buildScript() {
    const client = panel.client, projects = panel.projects, sync = pluginButton.syncEngine;
    let s = [];
    const add = function (x) { s = s.concat(x); };
    const syncButton = function () { return demo.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginSyncButton"); };
    add(say("QField + Mergin Maps: two-way sync"));
    add(pause(2500));
    add(say("Log in to Mergin Maps"));
    add(tap(function () { return demo.pluginButton; }));
    add(pause(800));
    add(type(function () { return demo.panelItem("merginLoginField"); }, "fielduser"));
    add(type(function () { return demo.panelItem("merginPasswordField"); }, "Field-Pass-123"));
    add(tap(function () { return demo.panelItem("merginLoginButton"); }));
    add(waitUntil(function () { return client.loggedIn && !projects.listing && projects.remoteProjects.length > 0; }));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(say("Projects, in the Mergin Maps app style"));
    add(pause(2500));
    add(say("Download the tree survey"));
    add(tap(projectButton("dummy-points")));
    add(waitUntil(function () { return !projects.downloading && sync.currentFullName === "mergin/dummy-points"; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(pause(2500));
    add(say("In the field: record a new tree"));
    add(pause(1500));
    add({ wait: 100, run: function () {
      const l = demo.treesLayer();
      l.startEditing();
      const f = QfFeatureUtils.createFeature(l, QfGeometryUtils.createGeometryFromWkt("POINT (-0.14175 50.82265)"));
      f.setAttribute("species", "Field Maple"); f.setAttribute("height_m", 5.5); f.setAttribute("surveyor", "fielduser");
      QfLayerUtils.addFeature(l, f);
      l.changeAttributeValue(1, l.fields.indexOf("species"), "Field Ash");
      l.commitChanges();
    } });
    add(pause(2500));
    add(say("Tap Sync"));
    add(tap(syncButton));
    add(waitUntil(function () { return !sync.syncing; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(say("Field edits pushed to the server as a geodiff changeset"));
    add(pause(3500));
    add(say("Meanwhile in the office, a colleague edits the same project"));
    add(server("office_edit"));
    add(pause(1500));
    add(say("Sync again: the office changes arrive"));
    add(tap(syncButton));
    add(waitUntil(function () { return !sync.syncing; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(say("Office edits merged in, field edits kept"));
    add(pause(3500));
    add(tap(function () { return demo.pluginButton; }));
    add(waitUntil(function () { return !projects.listing && projects.remoteProjects.length > 0; }));
    add(say("Project up to date"));
    add(pause(3500));
    add(say("geodiff runs inside QField: same changesets as Mergin Maps mobile and QGIS"));
    add(pause(3500));
    add({ wait: 0, run: function () { demo.log("DONE"); Qt.quit(); } });
    return s;
  }

  Timer {
    id: runner
    interval: 50; repeat: false
    property double waitStarted: 0
    onTriggered: {
      if (demo.stepIndex >= demo.steps.length) return;
      const step = demo.steps[demo.stepIndex];
      if (step.until) {
        if (waitStarted === 0) waitStarted = Date.now();
        if (!step.until() && Date.now() - waitStarted < step.timeout) { interval = 200; start(); return; }
        if (!step.until()) demo.log("timeout at step " + demo.stepIndex);
        waitStarted = 0;
      } else {
        try { step.run(); } catch (e) { demo.log("step " + demo.stepIndex + " failed: " + e); }
      }
      demo.stepIndex++;
      const next = demo.steps[demo.stepIndex];
      interval = next && next.wait !== undefined ? Math.max(1, next.wait) : 50;
      start();
    }
  }

  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: {
      const button = demo.findVisualChild(iface.findItemByObjectName("pluginsToolbar"), "merginPluginButton");
      if (!button || !qgisProject.fileName) return;
      running = false;
      iface.mainWindow().x = 0; iface.mainWindow().y = 0;
      iface.mainWindow().width = 540; iface.mainWindow().height = 960;
      button.panel.client.setServerUrl("http://127.0.0.1:5000");   // avoid contacting the production server first
      demo.overlay = iface.mainWindow().contentItem;
      demo.pluginButton = button;
      demo.signals = qgisProject.homePath + "/signals/";
      demo.panel = button.panel;
      demo.steps = demo.buildScript();
      demo.log("starting demo with " + demo.steps.length + " steps");
      runner.interval = 2000;
      runner.start();
    }
  }
}
