import QtQuick
import QtTest

import "../../plugin/js/trackingplan.js" as TrackingPlan

TestCase {
  name: "TrackingPlan"

  function test_tracking_layer_detection() {
    const all = ["fid", "tracking_start_time", "tracking_end_time", "total_distance", "tracked_by"];
    verify(TrackingPlan.isMerginTrackingLayer(all, true));
    verify(!TrackingPlan.isMerginTrackingLayer(all, false), "must be a line layer");
    verify(!TrackingPlan.isMerginTrackingLayer(["tracking_start_time", "tracked_by"], true), "all four fields");
  }

  function test_tracking_config_from_project() {
    // as written by the QGIS Mergin plugin (mobile test project test/test_data/tracking/tracking-project.qgz)
    const xml = '<properties><Mergin><PositionTracking>\n<Enabled type="int">1</Enabled>\n'
              + '<TrackingLayer type="QString">tracking_layer_aad89df7_21db_466e_b5c1_a80160f74c01</TrackingLayer>\n'
              + '<UpdateFrequency type="int">1</UpdateFrequency>\n</PositionTracking></Mergin></properties>';
    const config = TrackingPlan.trackingConfigFromProjectXml(xml);
    verify(config.enabled);
    compare(config.layerId, "tracking_layer_aad89df7_21db_466e_b5c1_a80160f74c01");
    compare(TrackingPlan.trackingConfigFromProjectXml("<properties/>"), null);
  }

  function test_user_set_fields() {
    const pre = new Date("2026-10-23T12:00:00Z");
    // straight from QField's form: pre-filled start and user, empty end and distance
    let set = TrackingPlan.userSetFields({ tracking_start_time: new Date(pre), tracked_by: "fielduser", tracking_end_time: null, total_distance: null }, pre, "fielduser", false);
    verify(!set.tracking_start_time && !set.tracked_by && !set.tracking_end_time && !set.total_distance, JSON.stringify(set));
    // the user changed the start and the name in the form, and typed a distance
    set = TrackingPlan.userSetFields({ tracking_start_time: new Date("2026-10-23T11:00:00Z"), tracked_by: "Sam", tracking_end_time: null, total_distance: 5 }, pre, "fielduser", false);
    verify(set.tracking_start_time && set.tracked_by && set.total_distance && !set.tracking_end_time, JSON.stringify(set));
    // a resumed track keeps its start and user, end and distance are recomputed
    set = TrackingPlan.userSetFields({ tracking_start_time: new Date(pre), tracked_by: "fielduser", tracking_end_time: new Date(pre), total_distance: 0.01 }, null, "fielduser", true);
    verify(set.tracking_start_time && set.tracked_by && !set.tracking_end_time && !set.total_distance, JSON.stringify(set));
  }

  function test_completion() {
    const first = new Date("2026-10-23T12:00:03Z"), end = new Date("2026-10-23T12:05:00Z");
    const current = { tracking_start_time: new Date("2026-10-23T11:59:50Z"), tracking_end_time: null, total_distance: null, tracked_by: "fielduser" };
    const computed = { tracking_start_time: first, tracking_end_time: end, total_distance: 0.01, tracked_by: "fielduser" };
    const names = ["tracking_start_time", "tracking_end_time", "total_distance", "tracked_by"];
    let updates = TrackingPlan.completion(current, computed, {}, names);
    compare(updates.map(function (u) { return u.name; }), ["tracking_start_time", "tracking_end_time", "total_distance"], "unchanged user not rewritten");
    updates = TrackingPlan.completion(current, computed, { tracking_start_time: true, total_distance: true }, names);
    compare(updates.map(function (u) { return u.name; }), ["tracking_end_time"], "user-set fields kept");
    updates = TrackingPlan.completion(current, { tracking_start_time: null }, {}, names);
    compare(updates.length, 0, "empty computed values never replace anything");
    updates = TrackingPlan.completion(current, computed, {}, ["tracking_end_time"]);
    compare(updates.map(function (u) { return u.name; }), ["tracking_end_time"], "only fields the layer has");
  }

  function test_track_filter_and_variables() {
    compare(TrackingPlan.trackFilterExpression(new Date(1792756803000), "o'brien"),
            "abs(epoch(\"tracking_start_time\") - 1792756803000) < 1000 AND \"tracked_by\" = 'o''brien'");
    const vars = TrackingPlan.merginVariables({ username: "fielduser", email: "f@example.com", fullName: "", projectName: "p", projectFullName: "ws/p", projectVersion: "v3", serverUrl: "https://app.merginmaps.com" });
    compare(vars.mm_username, "fielduser");
    compare(vars.mergin_username, "fielduser");
    compare(vars.mm_project_full_name, "ws/p");
    compare(vars.mm_project_version, "v3");
    compare(vars.mm_url, "https://app.merginmaps.com");
    verify(vars.mm_full_name === undefined, "empty values are not set");
  }
}
