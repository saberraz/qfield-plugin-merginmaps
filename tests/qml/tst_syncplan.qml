import QtQuick
import QtTest

import "../../plugin/js/syncplan.js" as Plan

TestCase {
  name: "SyncPlan"

  function test_isIgnored_data() {
    return [
      { tag: "metadata dir", path: ".mergin/mergin.json", ignored: true },
      { tag: "base copy", path: ".mergin/data/trees.gpkg", ignored: true },
      { tag: "wal", path: "trees.gpkg-wal", ignored: true },
      { tag: "shm", path: "sub/trees.gpkg-shm", ignored: true },
      { tag: "backup tilde", path: "project.qgs~", ignored: true },
      { tag: "qfield thumbnail qgz", path: "bees.qgz.png", ignored: true },
      { tag: "qfield thumbnail qgs", path: "dummy-points.qgs.png", ignored: true },
      { tag: "macOS junk", path: "DCIM/.DS_Store", ignored: true },
      { tag: "photo", path: "DCIM/2026-10-22.jpg", ignored: false },
      { tag: "png that is not a thumbnail", path: "maps/legend.png", ignored: false },
      { tag: "gpkg", path: "trees.gpkg", ignored: false },
      { tag: "dotted mergin-like name", path: "data/.merginx", ignored: false }
    ];
  }

  function test_isIgnored(data) {
    compare(Plan.isIgnored(data.path), data.ignored);
  }

  function test_compareFileSets() {
    const origin = [{ path: "a.gpkg", checksum: "1" }, { path: "b.jpg", checksum: "2" }, { path: "c.txt", checksum: "3" }];
    const current = [{ path: "a.gpkg", checksum: "9", size: 10 }, { path: "b.jpg", checksum: "2" }, { path: "d.jpg", checksum: "4" }];
    const ch = Plan.compareFileSets(origin, current);
    compare(ch.added.map(function (f) { return f.path; }), ["d.jpg"]);
    compare(ch.removed.map(function (f) { return f.path; }), ["c.txt"]);
    compare(ch.updated.length, 1);
    compare(ch.updated[0].path, "a.gpkg");
    compare(ch.updated[0].originChecksum, "1");
    compare(ch.updated[0].checksum, "9");
  }

  function test_conflict_names() {
    // same strings as mergin-client's utils.conflicted_copy_file_name / edit_conflict_file_name
    compare(Plan.conflictedCopyName("data.gpkg", "martin", 5), "data (conflicted copy, martin v5).gpkg");
    compare(Plan.conflictedCopyName("DCIM/photo.jpg", "fielduser", 3), "DCIM/photo (conflicted copy, fielduser v3).jpg");
    compare(Plan.conflictedCopyName("bees.qgz", "u", 2), "bees (conflicted copy, u v2).qgz~");
    compare(Plan.conflictedCopyName("archive.tar.gz", "u", 2), "archive (conflicted copy, u v2).tar.gz");
    compare(Plan.editConflictName("data.gpkg", "martin", 5), "data (edit conflict, martin v5).json");
    compare(Plan.editConflictName("sub/trees & shrubs.gpkg", "u", 7), "sub/trees & shrubs (edit conflict, u v7).json");
  }

  function test_uniquePath() {
    const taken = { "a.json": true, "a (1).json": true };
    compare(Plan.uniquePath("a.json", function (p) { return !!taken[p]; }), "a (2).json");
    compare(Plan.uniquePath("b.json", function (p) { return !!taken[p]; }), "b.json");
  }

  function test_versions_and_ids() {
    compare(Plan.versionNumber("v12"), 12);
    compare(Plan.versionNumber("v0"), 0);
    verify(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(Plan.uuid4()));
    compare(Plan.chunkIds(0, 10).length, 0);
    compare(Plan.chunkIds(10, 10).length, 1);
    compare(Plan.chunkIds(11, 10).length, 2);
  }

  function test_isVersioned() {
    verify(Plan.isVersioned("x.GPKG"));
    verify(Plan.isVersioned("a/b.sqlite"));
    verify(!Plan.isVersioned("a.gpkg.png"));
  }
}
