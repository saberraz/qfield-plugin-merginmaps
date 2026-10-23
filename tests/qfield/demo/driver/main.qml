import QtQuick
import QtQuick.Controls
import org.qfield

// Test-only app plugin that operates the real Mergin plugin UI at human pace for a screencast:
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

  function buildScript() {
    const client = panel.client, projects = panel.projects;
    let s = [];
    const add = function (x) { s = s.concat(x); };
    add(say("QField + Mergin Maps plugin"));
    add(pause(2500));
    add(say("Open the Mergin Maps plugin"));
    add(tap(function () { return demo.pluginButton; }));
    add(pause(1200));
    add(say("Point it at your Mergin Maps server"));
    add(type(function () { return demo.panelItem("merginServerField"); }, "http://127.0.0.1:5000"));
    add({ wait: 300, run: function () { demo.panelItem("merginServerField").editingFinished(); } });
    add(waitUntil(function () { return client.serverReachable; }, 10000));
    add(pause(800));
    add(say("Log in with your Mergin Maps account"));
    add(type(function () { return demo.panelItem("merginLoginField"); }, "fielduser"));
    add(type(function () { return demo.panelItem("merginPasswordField"); }, "Field-Pass-123"));
    add(tap(function () { return demo.panelItem("merginLoginButton"); }));
    add(waitUntil(function () { return client.loggedIn && !projects.listing && projects.remoteProjects.length > 0; }));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(say("Your projects on the server"));
    add(pause(2500));
    add(say("Download a real project: bee farming survey, with photos and an offline basemap"));
    add(tap(projectButton("bee-farming")));
    add(waitUntil(function () { return !projects.downloading && qgisProject.fileName.indexOf("bee-farming") > 0; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(say("Downloaded, checksum-verified and opened in QField"));
    add(pause(3500));
    add(say("Back to the project list"));
    add(tap(function () { return demo.pluginButton; }));
    add(waitUntil(function () { return !projects.listing && projects.remoteProjects.length > 0; }));
    add(pause(1200));
    add(say("Larger project (14 MB) with Unicode file names, downloaded in chunks"));
    add(tap(projectButton("dummy-edge-cases")));
    add(waitUntil(function () { return !projects.downloading && qgisProject.fileName.indexOf("dummy-edge-cases") > 0; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(pause(3000));
    add(say("Another real project: a wastewater network with three linked GeoPackages"));
    add(tap(function () { return demo.pluginButton; }));
    add(waitUntil(function () { return !projects.listing && projects.remoteProjects.length > 0; }));
    add(pause(1000));
    add(tap(projectButton("wastewater-network")));
    add(waitUntil(function () { return !projects.downloading && qgisProject.fileName.indexOf("wastewater-network") > 0; }, 60000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(pause(3500));
    add(say("Downloaded projects stay on the device"));
    add(tap(function () { return demo.pluginButton; }));
    add(waitUntil(function () { return !projects.listing && projects.remoteProjects.length > 0; }));
    add(pause(2500));
    add(say("Open the bee farming project again, offline"));
    add(tap(projectButton("bee-farming")));
    add(waitUntil(function () { return qgisProject.fileName.indexOf("bee-farming") > 0; }, 30000));
    add({ wait: 100, run: function () { touch.visible = false; } });
    add(pause(3500));
    add(say("Next: two-way sync of field edits with geodiff"));
    add(pause(3000));
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
      demo.panel = button.panel;
      demo.steps = demo.buildScript();
      demo.log("starting demo with " + demo.steps.length + " steps");
      runner.interval = 2000;
      runner.start();
    }
  }
}
