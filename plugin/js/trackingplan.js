.pragma library

// Pure helpers for Mergin Maps position tracking in QField (see qml/MerginTracking.qml).
//
// A Mergin Maps project can have a tracking layer (QGIS Mergin plugin: Project settings > Position tracking): a line
// layer with the fields below and default values "@tracking_start_time", "@tracking_end_time", "round($length, 2)" and
// "@mm_username". Mergin Maps mobile fills them when it saves a track; QField's own tracking does not know those
// variables, so the plugin provides them and completes the track's attributes.

var START = "tracking_start_time";
var END = "tracking_end_time";
var DISTANCE = "total_distance";
var USER = "tracked_by";
var FIELDS = [START, END, DISTANCE, USER];

// A layer is treated as the Mergin tracking layer if it is a line layer with all four fields.
function isMerginTrackingLayer(fieldNames, isLineLayer) {
  if (!isLineLayer || !fieldNames) return false;
  for (var i = 0; i < FIELDS.length; i++) {
    if (fieldNames.indexOf(FIELDS[i]) < 0) return false;
  }
  return true;
}

// Mergin project entries in a .qgs file: <Mergin><PositionTracking><Enabled/><TrackingLayer/>...
// Returns { enabled, layerId } or null when the project has no tracking configuration.
function trackingConfigFromProjectXml(xml) {
  var block = /<PositionTracking>([\s\S]*?)<\/PositionTracking>/.exec(String(xml || ""));
  if (!block) return null;
  var layer = /<TrackingLayer[^>]*>([^<]*)<\/TrackingLayer>/.exec(block[1]);
  var enabled = /<Enabled[^>]*>([^<]*)<\/Enabled>/.exec(block[1]);
  return {
    enabled: enabled ? (enabled[1] === "1" || enabled[1].toLowerCase() === "true") : false,
    layerId: layer ? layer[1].trim() : ""
  };
}

function isEmpty(value) {
  return value === undefined || value === null || value === "" || (typeof value === "number" && isNaN(value));
}

function sameInstant(a, b) {
  if (isEmpty(a) || isEmpty(b)) return false;
  var ta = new Date(a).getTime(), tb = new Date(b).getTime();
  return !isNaN(ta) && ta === tb;
}

// Which of the four fields the user set themselves, judged from the attributes the track started with.
//   initial:   the track feature's attributes when tracking started (after QField's form)
//   prefilledStart: the value @tracking_start_time had when the form was filled ("" if unknown)
//   username:  the Mergin username (the value @mm_username gives)
//   resumed:   the track already existed (QField's "Resume tracking")
// End time and distance are empty by default (no end yet, no geometry), so a value there was typed. On a resumed track
// they hold the previous completion and are recomputed.
function userSetFields(initial, prefilledStart, username, resumed) {
  initial = initial || {};
  var set = {};
  set[START] = !isEmpty(initial[START]) && (resumed || !sameInstant(initial[START], prefilledStart));
  set[USER] = !isEmpty(initial[USER]) && (resumed || initial[USER] !== username);
  set[END] = !resumed && !isEmpty(initial[END]);
  set[DISTANCE] = !resumed && !isEmpty(initial[DISTANCE]);
  return set;
}

// Attribute updates for a track: computed values (from the layer's own default expressions) for every field the user
// did not set. Returns [{ name, value }] for fields present in the layer whose value changes.
function completion(current, computed, userSet, fieldNames) {
  var updates = [];
  for (var i = 0; i < FIELDS.length; i++) {
    var name = FIELDS[i];
    if (fieldNames && fieldNames.indexOf(name) < 0) continue;
    if (userSet && userSet[name]) continue;
    var value = computed ? computed[name] : undefined;
    if (isEmpty(value)) continue;   // nothing better to offer
    var old = current ? current[name] : undefined;
    var unchanged = (value instanceof Date || old instanceof Date) ? sameInstant(old, value) : old === value;
    if (!unchanged) updates.push({ name: name, value: value });
  }
  return updates;
}

// QGIS expression selecting the track again after a sync (a rebase can renumber a locally inserted feature).
function trackFilterExpression(startTime, username) {
  var ms = new Date(startTime).getTime();
  var user = String(username || "").replace(/'/g, "''");
  // within a second: a GeoPackage datetime may not keep milliseconds
  return 'abs(epoch("' + START + '") - ' + ms + ') < 1000 AND "' + USER + '" = \'' + user + "'";
}

// Expression variables Mergin Maps mobile provides (variablesmanager.cpp), with the older "mergin_" names.
//   info: { username, email, fullName, serverUrl, projectName, projectFullName, projectVersion }
function merginVariables(info) {
  info = info || {};
  var pairs = [
    ["username", info.username], ["user_email", info.email], ["full_name", info.fullName], ["url", info.serverUrl],
    ["project_name", info.projectName], ["project_full_name", info.projectFullName], ["project_version", info.projectVersion]
  ];
  var vars = {};
  pairs.forEach(function (p) {
    if (isEmpty(p[1])) return;
    vars["mm_" + p[0]] = String(p[1]);
    vars["mergin_" + p[0]] = String(p[1]);
  });
  return vars;
}
