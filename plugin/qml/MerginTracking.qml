import QtQuick

import org.qgis
import org.qfield

import "../js/merginutils.js" as MerginUtils
import "../js/trackingplan.js" as TrackingPlan

// Mergin Maps position tracking on top of QField's own tracking (which this component never changes).
//
//  - Expression variables: @mm_username, @mm_project_name, ... (and the older @mergin_* names), as Mergin Maps mobile
//    provides them, set as in-memory project variables of an open Mergin project. Default values that use them now work
//    in QField forms, including the tracking layer's "@mm_username".
//  - @tracking_start_time is set when QField's Tracking dialog opens, so its form shows a start time.
//  - The track's attributes on the Mergin tracking layer are completed with the layer's own default expressions
//    (QfFeatureModel.resetAttributes, the same QgsVectorLayerUtils::createFeature path Mergin Maps mobile uses):
//    start = first recorded point, end = now, distance from the geometry, user. Values the user set are kept.
//    This happens when a sync starts (the server gets a consistent partial track) and when tracking stops.
//  - Sync swaps the open project, which makes QField drop its trackers. pauseForSync()/resumeAfterSync() save them and
//    continue the same features afterwards, with the original start (so "elapsed time" M values keep counting).
//    Positions during the sync are not recorded: the track has a straight segment over that gap.
Item {
  id: tracking

  property MerginClient client
  property MerginProjects projects
  property MerginSync sync
  property MerginWorkspaces workspaces

  // layer id -> { layerId, mergin, fid, startTime, trackerStart, initial, userSet, resumed, paused }
  // (a Map: deleting and re-adding object keys is the pattern behind the V4 crash QTBUG-147153)
  property var sessions: new Map()
  property var prefilledStart: null       // @tracking_start_time when the Tracking dialog opened
  property var trackerSettings: null

  function log(message) { client.log("Tracking: " + message); }

  // ---- layers ----

  function vectorLayers() {
    const layers = QfProjectUtils.mapLayers(qgisProject);
    const list = [];
    for (const id in layers) {
      if (layers[id] && layers[id].fields !== undefined) list.push(layers[id]);
    }
    return list;
  }

  function layerById(id) {
    const layers = QfProjectUtils.mapLayers(qgisProject);
    return layers[id] || null;
  }

  function fieldNames(layer) {
    return TrackingPlan.FIELDS.filter(function (name) { return layer.fields.indexOf(name) >= 0; });
  }

  // The Mergin tracking layer: named in the project's Mergin settings (readable for .qgs projects), otherwise
  // recognised by its fields.
  function isMerginTrackingLayer(layer) {
    if (!layer || sync.currentFullName === "") return false;
    const configured = configuredTrackingLayerId();
    if (configured !== "") return layer.id === configured;
    return TrackingPlan.isMerginTrackingLayer(fieldNames(layer), layer.geometryType() === Qgis.GeometryType.Line);
  }

  property string _configProject: ""
  property string _configLayerId: ""
  function configuredTrackingLayerId() {
    const path = qgisProject.fileName;
    if (path !== _configProject) {
      _configProject = path;
      _configLayerId = "";
      if (path.toLowerCase().endsWith(".qgs")) {
        try {
          const config = TrackingPlan.trackingConfigFromProjectXml(MerginUtils.utf8Decode(QfFileUtils.readFileContent(path)));
          if (config && config.layerId) _configLayerId = config.layerId;
        } catch (e) {
          _configLayerId = "";
        }
      }
    }
    return _configLayerId;
  }

  // QgsFeature has no isValid in QML: a feature that was not found has the null id
  function exists(feature, fid) {
    return feature && feature.id === fid && fid >= 0;
  }

  function attributes(feature) {
    const values = {};
    TrackingPlan.FIELDS.forEach(function (name) { values[name] = feature.attribute(name); });
    return values;
  }

  // ---- expression variables ----

  function applyVariables() {
    const p = sync.projectFromPath(qgisProject.fileName);
    if (!p) return;
    const local = projects.findLocal(p.namespace, p.name);
    const vars = TrackingPlan.merginVariables({
      username: client.username, email: client.email, fullName: workspaces ? workspaces.fullName : "",
      serverUrl: client.serverUrl, projectName: p.name, projectFullName: MerginUtils.projectFullName(p.namespace, p.name),
      projectVersion: local ? local.version : projects.localVersion(p.namespace, p.name)
    });
    for (const name in vars) QfExpressionContextUtils.setProjectVariable(qgisProject, name, vars[name]);
  }

  Connections {
    target: iface
    function onLoadProjectEnded(path, name) { Qt.callLater(tracking.applyVariables); }
  }
  Connections {
    target: tracking.client
    function onLoginFinished(ok, message) { if (ok) tracking.applyVariables(); }
  }
  Connections {
    target: tracking.workspaces
    function onFullNameChanged() { tracking.applyVariables(); }
  }

  // ---- QField's tracking: dialog, start, progress, stop ----

  Connections {
    target: tracking.trackerSettings
    function onOpened() {
      if (tracking.sync.currentFullName === "") return;
      tracking.prefilledStart = new Date();
      QfExpressionContextUtils.setProjectVariable(qgisProject, "tracking_start_time", tracking.prefilledStart);
      QfExpressionContextUtils.removeProjectVariable(qgisProject, "tracking_end_time");
      tracking.applyVariables();
    }
  }

  Connections {
    target: trackingModel
    function onLayerInTrackingChanged(layer, active) {
      if (active) tracking.trackingStarted(layer); else tracking.trackingStopped(layer);
    }
  }

  function trackingStarted(layer) {
    const existing = sessions.get(layer.id);
    if (existing && existing.paused) return;   // our own resume after a sync
    const tracker = trackingModel.trackerForLayer(layer);
    if (!tracker) return;
    const feature = tracker.feature;
    const resumed = feature.id >= 0;
    const mergin = isMerginTrackingLayer(layer);
    const initial = mergin ? attributes(feature) : {};
    sessions.set(layer.id, {
      layerId: layer.id, mergin: mergin, fid: resumed ? feature.id : -1, startTime: null, trackerStart: null,
      initial: initial, resumed: resumed,
      userSet: mergin ? TrackingPlan.userSetFields(initial, prefilledStart, client.username, resumed) : {},
      paused: false
    });
    if (mergin) {
      const set = sessions.get(layer.id).userSet;
      log("started on " + layer.name + (resumed ? " (resumed feature " + feature.id + ")" : "")
          + "; kept as set in the form: " + (Object.keys(set).filter(function (k) { return set[k]; }).join(", ") || "none"));
    }
    progress.start();
  }

  // QField deletes the tracker before announcing the stop: the session already holds its feature id and start
  function trackingStopped(layer) {
    const session = sessions.get(layer.id);
    if (!session || session.paused) return;
    sessions.delete(layer.id);
    if (session.mergin && session.fid >= 0) {
      completeTrack(layer, session);
      log("stopped on " + layer.name + ", feature " + session.fid + " completed");
    }
  }

  // feature id (known from the 3rd point on) and the first point's time, while tracking runs
  Timer {
    id: progress
    interval: 250
    repeat: true
    onTriggered: {
      let any = false;
      tracking.sessions.forEach(function (session, id) {
        if (session.paused) { any = true; return; }
        const layer = tracking.layerById(id);
        const tracker = layer ? trackingModel.trackerForLayer(layer) : null;
        if (!tracker) return;
        any = true;
        if (tracker.feature.id >= 0) session.fid = tracker.feature.id;
        if (!session.startTime) session.startTime = tracking.firstPointTime(tracker);
      });
      if (!any) stop();
    }
  }

  // The time of the track's first point: QField's session start when it has one. QField starts a session without it
  // when no position is available yet (e.g. right after its positioning source restarts); the time of the position
  // that produced the first vertex is used then (this timer runs every 250 ms while the session has no start).
  function firstPointTime(tracker) {
    const start = tracker.startPositionTimestamp ? new Date(tracker.startPositionTimestamp) : null;
    if (start && !isNaN(start.getTime()) && start.getTime() > 0) return start;
    if (tracker.rubberbandModel && tracker.rubberbandModel.vertexCount > 0) {
      const source = iface.findItemByObjectName("positionSource");
      const utc = source && source.positionInformation ? new Date(source.positionInformation.utcDateTime) : null;
      return utc && !isNaN(utc.getTime()) ? utc : new Date();
    }
    return null;
  }

  // ---- completing a track ----

  QfFeatureModel {
    id: computeModel
    project: qgisProject
  }

  // Writes start (first point), end (now), distance and user, computed with the layer's own default expressions, into
  // the fields the user did not set. The layer must not be in active tracking (QField would overwrite the edit).
  function completeTrack(layer, session) {
    const feature = layer.getFeature(session.fid);
    if (!exists(feature, session.fid)) {
      log("track feature " + session.fid + " not found on " + layer.name);
      return false;
    }
    const start = session.startTime || (session.resumed ? feature.attribute(TrackingPlan.START) : null) || prefilledStart;
    if (start) QfExpressionContextUtils.setProjectVariable(qgisProject, "tracking_start_time", start);
    QfExpressionContextUtils.setProjectVariable(qgisProject, "tracking_end_time", new Date());
    applyVariables();
    computeModel.currentLayer = layer;
    computeModel.feature = feature;
    computeModel.resetAttributes(true);
    const computed = attributes(computeModel.feature);
    QfExpressionContextUtils.removeProjectVariable(qgisProject, "tracking_end_time");
    const updates = TrackingPlan.completion(attributes(feature), computed, session.userSet, fieldNames(layer));
    const startUpdate = updates.filter(function (u) { return u.name === TrackingPlan.START; })[0];
    session.storedStart = startUpdate ? startUpdate.value : feature.attribute(TrackingPlan.START);
    if (updates.length === 0) return true;
    layer.startEditing();
    updates.forEach(function (u) { layer.changeAttributeValue(session.fid, layer.fields.indexOf(u.name), u.value); });
    const ok = layer.commitChanges();
    log("completed feature " + session.fid + ": " + updates.map(function (u) { return u.name; }).join(", ") + (ok ? "" : " (commit failed)"));
    return ok;
  }

  // ---- sync ----

  // Before sync swaps the project: stop recording (QField's pause, which commits), complete Mergin tracks, save every
  // active tracker. Returns what resumeAfterSync() needs.
  function pauseForSync() {
    const paused = [];
    const projectInfo = iface.findItemByObjectName("projectInfo");
    vectorLayers().forEach(function (layer) {
      if (!trackingModel.layerInActiveTracking(layer)) return;
      const tracker = trackingModel.trackerForLayer(layer);
      let session = sessions.get(layer.id);
      if (!session) {
        // tracking started before the plugin saw it: keep whatever the feature already has
        const mergin = isMerginTrackingLayer(layer);
        const initial = mergin ? attributes(tracker.feature) : {};
        session = { layerId: layer.id, mergin: mergin, fid: -1, startTime: null, trackerStart: null, initial: initial,
                    userSet: mergin ? TrackingPlan.userSetFields(initial, null, client.username, true) : {}, resumed: true };
        sessions.set(layer.id, session);
      }
      if (tracker.feature.id >= 0) session.fid = tracker.feature.id;
      if (!session.startTime) session.startTime = firstPointTime(tracker);
      session.trackerStart = tracker.startPositionTimestamp;
      session.paused = true;
      paused.push(session);
    });
    if (paused.length === 0) return paused;
    trackingModel.suspendUntilReplay();
    paused.forEach(function (session) {
      const layer = layerById(session.layerId);
      if (session.mergin && session.fid >= 0) completeTrack(layer, session);
      if (projectInfo) projectInfo.saveTracker(layer);
    });
    log("paused " + paused.length + " tracker(s) for sync");
    return paused;
  }

  // After the project is open again: restore the trackers on the same features and continue recording.
  function resumeAfterSync(paused) {
    if (!paused || paused.length === 0) return;
    const projectInfo = iface.findItemByObjectName("projectInfo");
    paused.forEach(function (session) {
      const layer = layerById(session.layerId);
      if (!layer || !projectInfo) {
        log("could not resume tracking on layer " + session.layerId);
        sessions.delete(session.layerId);
        return;
      }
      projectInfo.restoreTracker(layer);
      const tracker = trackingModel.trackerForLayer(layer);
      if (!tracker) {
        sessions.delete(session.layerId);
        return;
      }
      if (session.mergin && session.fid >= 0) {
        // a rebase can renumber a feature inserted here: find the track by its start and user
        const fid = findTrack(layer, session);
        if (fid >= 0 && fid !== session.fid) log("track feature renumbered by the sync: " + session.fid + " -> " + fid);
        if (fid >= 0) {
          session.fid = fid;
          if (tracker.feature.id !== fid) tracker.feature = layer.getFeature(fid);
        } else {
          // never continue on a feature that is not ours (after a rebase it may be a colleague's track)
          log("track feature " + session.fid + " not found after the sync: continuing as a new track");
          tracker.feature = QfFeatureUtils.createFeature(layer, QfGeometryUtils.createGeometryFromWkt(""));
          session.fid = -1;
        }
      }
      if (session.trackerStart) tracker.startPositionTimestamp = session.trackerStart;
      trackingModel.startTracker(layer);     // no position: live positions continue the line
      session.paused = false;
      log("resumed tracking on " + layer.name + (session.fid >= 0 ? ", feature " + session.fid : ""));
    });
    progress.start();
  }

  // The track's start time was written when the sync paused it (completeTrack), so start + user identify it.
  function findTrack(layer, session) {
    const start = session.storedStart || session.startTime;
    const current = layer.getFeature(session.fid);
    if (exists(current, session.fid) && current.attribute(TrackingPlan.USER) === client.username
        && (!start || TrackingPlan.sameInstant(current.attribute(TrackingPlan.START), start))) {
      return session.fid;
    }
    if (!start) return -1;
    const it = QfLayerUtils.createFeatureIteratorFromExpression(layer, TrackingPlan.trackFilterExpression(start, client.username));
    let fid = -1;
    if (it.hasNext()) fid = it.next().id;
    it.close();
    return fid;
  }

  Component.onCompleted: {
    trackerSettings = iface.findItemByObjectName("trackerSettings");
  }
}
