import QtQuick

import org.qfield

import "../js/merginutils.js" as MerginUtils
import "../js/syncplan.js" as Plan

// Two-way synchronisation of the open Mergin project, following the official mergin-client:
//   1. load the project folder's stub: releases the project's GeoPackages (WAL merged) and keeps the folder writable
//   2. local changes = files on disk vs .mergin/mergin.json; GeoPackages only count if geodiff finds row changes
//   3. pull when the server version moved on: changed files are downloaded; GeoPackages with local edits are rebased
//      (geodiff rebase, edit-conflict JSON); other files edited on both sides become "conflicted copies".
//      Local files are backed up first and restored if anything fails.
//   4. push (v1 transaction, 10 MB chunks); GeoPackage updates are uploaded as geodiff changesets that are
//      verified first: base + changeset must reproduce the local file exactly, otherwise nothing is pushed
//   5. update mergin.json and base copies, reopen the project
Item {
  id: sync

  property MerginClient client
  property MerginProjects projects
  // optional: keeps QField's tracking going across the project swap (MerginTracking.qml)
  property var tracking: null

  property bool syncing: false
  property real progress: 0
  property string statusText: ""
  // "<namespace>/<name>" of the open project if it is a downloaded Mergin project, otherwise ""
  property string currentFullName: ""

  signal syncFinished(bool ok, string message)

  // Snapshot of the map taken before the project is released, shown while syncing (the home stub is an empty map).
  property var snapshot: null

  readonly property int chunkSize: MerginUtils.DOWNLOAD_CHUNK_SIZE

  GeodiffWorker { id: geodiff }
  QfLocalFilesModel { id: filesModel }

  Connections {
    target: iface
    function onLoadProjectEnded(path, name) { sync.updateCurrent(); }
  }
  Component.onCompleted: updateCurrent()

  // ---- project detection ----

  // the open project counts only if it is the Mergin project's own QGIS file, not the folder's stub
  function projectFromPath(path) {
    const p = projects.projectForPath(path);
    return p && path !== p.stub ? p : null;
  }

  function updateCurrent() {
    const p = projectFromPath(qgisProject.fileName);
    currentFullName = p && projects.hasMetadata(p.dir) ? p.namespace + "/" + p.name : "";
  }

  // ---- small file helpers (all paths absolute; the home stub must be loaded) ----

  function sha1(path) { return MerginUtils.hexFromBuffer(QfFileUtils.fileChecksum(path, 2)); }
  function readJson(path) { return JSON.parse(MerginUtils.utf8Decode(QfFileUtils.readFileContent(path))); }
  function writeJson(path, obj) { return QfFileUtils.writeFileContent(path, MerginUtils.utf8Encode(JSON.stringify(obj))); }
  function read(path) { return QfFileUtils.readFileContent(path); }
  function write(path, buffer) {
    if (!QfFileUtils.writeFileContent(path, buffer)) throw new Error(qsTr("Could not write %1").arg(path));
  }
  // QField lets plugins delete only media files (QfFileUtils::isDeletable). Anything else is truncated instead and
  // false is returned; callers that need the file gone record a tombstone (see scanLocal).
  function remove(path) {
    if (!QfFileUtils.fileExists(path)) return true;
    if (QfFileUtils.deleteFiles([path])[path]) return true;
    QfFileUtils.writeFileContent(path, new ArrayBuffer(0));
    return false;
  }

  // Tombstones: { path: checksum } of files removed on the server that could not be deleted here. They are left
  // out of local changes while their content is unchanged, so they are not pushed back as new files.
  function readTombstones(dir) {
    const path = dir + "/.mergin/removed.json";
    if (!QfFileUtils.fileExists(path) || Number(QfFileUtils.getFileInfo(path).fileSize) === 0) return {};
    try { return readJson(path); } catch (e) { return {}; }
  }

  // Every file in the project folder that sync handles, with checksum and size.
  // QField has no directory listing API for plugins: QfLocalFilesModel finds new files (it lists folders and the file
  // types QField knows: data, images, audio, video, text), and known files are always checked directly.
  function scanLocal(dir, metaFiles, stub) {
    const found = {};
    const stack = [dir];
    while (stack.length) {
      const d = stack.pop();
      filesModel.resetToPath(d);
      const n = filesModel.rowCount();
      for (let i = 0; i < n; i++) {
        const item = filesModel.get(i);
        if (item.type === QfLocalFilesModel.SimpleFolder) {
          stack.push(item.path);
        } else if (item.path.indexOf(dir + "/") === 0) {
          found[item.path.substring(dir.length + 1)] = true;
        }
      }
    }
    metaFiles.forEach(function (f) { if (QfFileUtils.fileExists(dir + "/" + f.path)) found[f.path] = true; });
    const tracked = {};
    metaFiles.forEach(function (f) { tracked[f.path] = true; });
    const tombstones = readTombstones(dir);
    const stubPath = stub && stub.indexOf(dir + "/") === 0 ? stub.substring(dir.length + 1) : "";
    return Object.keys(found).filter(function (p) { return !Plan.isIgnored(p) && p !== stubPath; }).sort().map(function (p) {
      return { path: p, checksum: sha1(dir + "/" + p), size: Number(QfFileUtils.getFileInfo(dir + "/" + p).fileSize) };
    }).filter(function (f) { return tracked[f.path] || tombstones[f.path] !== f.checksum; });
  }

  // ---- entry point ----

  function syncCurrent() {
    if (syncing) return;
    const p = projectFromPath(qgisProject.fileName);
    if (!p || currentFullName === "") {
      syncFinished(false, qsTr("The open project is not a Mergin Maps project"));
      return;
    }
    const projectFile = qgisProject.fileName;
    syncing = true;
    progress = 0;
    statusText = qsTr("Synchronising project changes");
    client.log("Sync " + currentFullName + " started");

    const state = { p: p, projectFile: projectFile, backups: [], pulled: false, pushed: false, retried: false, tmp: [] };
    const finish = function (ok, message) {
      state.tmp.forEach(function (t) { sync.remove(t); });
      if (!ok) sync.restoreBackups(state);
      if (state.meta && state.meta.version) projects.setLocalVersion(p.namespace, p.name, state.meta.version);
      state.backups.forEach(function (b) { sync.remove(b.backup); });
      projects.loadProject(state.projectFile, function () {
        sync.syncing = false;
        sync.statusText = "";
        sync.progress = ok ? 1 : 0;
        sync.updateCurrent();
        if (sync.tracking) {
          try { sync.tracking.resumeAfterSync(state.trackers); } catch (e) { client.log("Tracking: resume failed: " + e); }
        }
        client.log("Sync " + p.namespace + "/" + p.name + (ok ? " finished: " : " failed: ") + message);
        sync.syncFinished(ok, message);
      });
    };

    const start = function () {
      // QField drops its trackers when the project changes: pause them (tracks completed and saved) and resume after
      state.trackers = [];
      if (sync.tracking) {
        try { state.trackers = sync.tracking.pauseForSync(); } catch (e) { client.log("Tracking: pause failed: " + e); }
      }
      projects.withProjectReleased(state.p, function (loaded, message) {
        if (!loaded) { finish(false, message); return; }
        try {
          sync.pullThenPush(state, finish);
        } catch (e) {
          finish(false, String(e));
        }
      });
    };
    let grabbing = false;
    try {
      const canvas = iface.mapCanvas();
      grabbing = canvas ? canvas.grabToImage(function (result) { sync.snapshot = result; start(); }) : false;
    } catch (e) {
      grabbing = false;
    }
    if (!grabbing) {
      snapshot = null;
      start();
    }
  }

  function guard(finish, fn) {
    return function () {
      try { fn.apply(null, arguments); } catch (e) { client.log("sync error: " + e + " " + (e.stack || "")); finish(false, String(e.message || e)); }
    };
  }

  // ---- 2 + 3: local changes and pull ----

  function pullThenPush(state, finish) {
    const dir = state.p.dir;
    state.meta = readJson(dir + "/.mergin/mergin.json");
    statusText = qsTr("Checking for changes");
    client.authRequest("GET", "v1/project/" + encodeURIComponent(state.p.namespace) + "/" + encodeURIComponent(state.p.name), undefined, guard(finish, function (server) {
      progress = 0.1;
      if (String(server.version) === String(state.meta.version)) {
        sync.push(state, finish);
        return;
      }
      sync.pull(state, server, finish);
    }), function (message) { finish(false, message); });
  }

  // Which versioned files have real local edits (geodiff), as { path: true }.
  function localVersionedEdits(dir, local, metaFiles, done) {
    const changes = Plan.compareFileSets(metaFiles, local);
    const candidates = changes.updated.filter(function (f) { return Plan.isVersioned(f.path) && QfFileUtils.fileExists(dir + "/.mergin/" + f.path); });
    const edited = {};
    changes.added.forEach(function (f) { edited[f.path] = true; });
    changes.updated.filter(function (f) { return !Plan.isVersioned(f.path); }).forEach(function (f) { edited[f.path] = true; });
    let i = 0;
    const next = function () {
      if (i >= candidates.length) { done(edited); return; }
      const f = candidates[i++];
      geodiff.run({ "base": read(dir + "/.mergin/" + f.path), "local": read(dir + "/" + f.path) },
                  [{ fn: "createChangeset", args: ["@base", "@local", "@d"] }, { fn: "changesCount", args: ["@d"] }], [],
                  function (r) {
                    // unreadable/changed schema counts as edited (full upload later)
                    edited[f.path] = r.error !== "" || r.results.length < 2 || r.results[1].rc !== 0 || r.results[1].value > 0;
                    next();
                  });
    };
    next();
  }

  function backup(state, relPath) {
    const src = state.p.dir + "/" + relPath;
    if (!QfFileUtils.fileExists(src) || state.backups.some(function (b) { return b.path === relPath; })) return;
    const b = state.p.dir + "/.mergin/backup/" + relPath;
    write(b, read(src));
    state.backups.push({ path: relPath, backup: b });
  }

  function restoreBackups(state) {
    state.backups.forEach(function (b) {
      try { sync.write(state.p.dir + "/" + b.path, sync.read(b.backup)); } catch (e) { client.log("restore failed for " + b.path + ": " + e); }
    });
    if (state.backups.length) client.log("Restored " + state.backups.length + " local file(s) after a failed sync");
  }

  function downloadFile(state, server, file, done, fail) {
    const ranges = MerginUtils.chunkRanges(Number(file.size || 0), chunkSize);
    const buffer = new Uint8Array(Number(file.size || 0));
    const path = "v1/project/raw/" + encodeURIComponent(state.p.namespace) + "/" + encodeURIComponent(state.p.name);
    let r = 0;
    const next = function () {
      if (r >= ranges.length) { done(buffer.buffer); return; }
      const range = ranges[r++];
      client.authDownloadRange(path, MerginUtils.rawFileQuery(file.path, String(server.version)), range[0], range[1], function (data) {
        buffer.set(new Uint8Array(data), range[0]);
        next();
      }, fail);
    };
    next();
  }

  function pull(state, server, finish) {
    const dir = state.p.dir;
    const user = client.username;
    const localVersion = Plan.versionNumber(state.meta.version);
    const metaMap = {};
    state.meta.files.forEach(function (f) { metaMap[f.path] = f; });
    const local = scanLocal(dir, state.meta.files, state.p.stub);
    const localMap = {};
    local.forEach(function (f) { localMap[f.path] = f; });
    const unsafe = server.files.filter(function (f) { return !MerginUtils.isSafeRelativePath(f.path); });
    if (unsafe.length) { finish(false, qsTr("The project contains an invalid file path: %1").arg(unsafe[0].path)); return; }

    const sc = Plan.serverChanges(state.meta.files, server.files);
    const todo = sc.added.concat(sc.updated);
    statusText = qsTr("Downloading changes (%1)").arg(server.version);
    client.log("Pull " + state.meta.version + " -> " + server.version + ": " + todo.length + " changed, " + sc.removed.length + " removed");

    localVersionedEdits(dir, local, state.meta.files, guard(finish, function (edited) {
      let i = 0;
      const next = guard(finish, function () {
        if (i >= todo.length) {
          // files removed on the server: delete local copies that were not edited here
          const tombstones = sync.readTombstones(dir);
          let tombstoned = false;
          sc.removed.forEach(function (f) {
            if (localMap[f.path] && !edited[f.path]) {
              sync.backup(state, f.path);
              if (!sync.remove(dir + "/" + f.path)) {
                tombstones[f.path] = sync.sha1(dir + "/" + f.path);
                tombstoned = true;
              }
              sync.remove(dir + "/.mergin/" + f.path);
            }
          });
          if (tombstoned) sync.writeJson(dir + "/.mergin/removed.json", tombstones);
          state.meta = server;
          state.pulled = true;
          sync.writeJson(dir + "/.mergin/mergin.json", server);
          // the pull is committed (files + metadata consistent): backups are no longer needed for recovery
          state.backups.forEach(function (b) { sync.remove(b.backup); });
          state.backups = [];
          sync.push(state, finish);
          return;
        }
        const f = todo[i++];
        progress = 0.1 + 0.4 * i / Math.max(1, todo.length);
        statusText = qsTr("Downloading %1").arg(f.path);
        sync.downloadFile(state, server, f, guard(finish, function (theirs) {
          const target = dir + "/" + f.path;
          const hasLocal = !!localMap[f.path];
          const locallyEdited = hasLocal && !!edited[f.path];
          if (Plan.isVersioned(f.path) && hasLocal && locallyEdited && metaMap[f.path] && QfFileUtils.fileExists(dir + "/.mergin/" + f.path)) {
            // GeoPackage changed on both sides: rebase local edits on top of the server version
            sync.backup(state, f.path);
            geodiff.run({ "base": sync.read(dir + "/.mergin/" + f.path), "their": theirs, "local": sync.read(target) },
                        [{ fn: "rebase", args: ["@base", "@their", "@local", "@conflicts.json"] }], ["local", "conflicts.json"],
                        guard(finish, function (r) {
                          if (r.error === "" && r.results.length && r.results[0].rc === 0) {
                            sync.write(target, r.outputs["local"]);
                            if (r.outputs["conflicts.json"]) {
                              const name = Plan.uniquePath(Plan.editConflictName(f.path, user, localVersion), function (p) { return QfFileUtils.fileExists(dir + "/" + p); });
                              sync.write(dir + "/" + name, r.outputs["conflicts.json"]);
                              client.log("Edit conflicts in " + f.path + " written to " + name);
                            }
                          } else {
                            // rebase impossible: keep local edits as a conflicted copy, take the server version
                            const copy = Plan.uniquePath(Plan.conflictedCopyName(f.path, user, localVersion), function (p) { return QfFileUtils.fileExists(dir + "/" + p); });
                            sync.write(dir + "/" + copy, sync.read(target));
                            sync.write(target, theirs);
                            client.log("Rebase of " + f.path + " failed (" + (r.error || (r.results[0] && r.results[0].error)) + "), local copy kept as " + copy);
                          }
                          sync.write(dir + "/.mergin/" + f.path, theirs);
                          next();
                        }));
            return;
          }
          if (hasLocal && localMap[f.path].checksum !== f.checksum && (locallyEdited || !metaMap[f.path])) {
            // edited (or added) here and changed on the server: keep ours as a conflicted copy
            const copy = Plan.uniquePath(Plan.conflictedCopyName(f.path, user, localVersion), function (p) { return QfFileUtils.fileExists(dir + "/" + p); });
            sync.write(dir + "/" + copy, sync.read(target));
            client.log("Conflict on " + f.path + ", local copy kept as " + copy);
          }
          if (hasLocal) sync.backup(state, f.path);
          sync.write(target, theirs);
          if (Plan.isVersioned(f.path)) sync.write(dir + "/.mergin/" + f.path, theirs);
          next();
        }), function (message) { finish(false, message); });
      });
      next();
    }));
  }

  // ---- 4 + 5: push ----

  function push(state, finish) {
    const dir = state.p.dir;
    statusText = qsTr("Preparing upload");
    const local = scanLocal(dir, state.meta.files, state.p.stub);
    const changes = Plan.compareFileSets(state.meta.files, local);
    const added = changes.added.slice();
    const removed = changes.removed.slice();
    const updated = [];
    let i = 0;
    const versionedUpdates = changes.updated.filter(function (f) { return Plan.isVersioned(f.path) && QfFileUtils.fileExists(dir + "/.mergin/" + f.path); });
    changes.updated.filter(function (f) { return !(Plan.isVersioned(f.path) && QfFileUtils.fileExists(dir + "/.mergin/" + f.path)); })
           .forEach(function (f) { updated.push({ path: f.path, checksum: f.checksum, size: f.size }); });

    const nextDiff = guard(finish, function () {
      if (i < versionedUpdates.length) {
        const f = versionedUpdates[i++];
        // changeset base -> local, then prove it: base + changeset must equal local (0 changes left)
        geodiff.run({ "base": sync.read(dir + "/.mergin/" + f.path), "local": sync.read(dir + "/" + f.path) },
                    [{ fn: "createChangeset", args: ["@base", "@local", "@diff"] },
                     { fn: "changesCount", args: ["@diff"] },
                     { fn: "copy", args: ["@base", "@check"] },
                     { fn: "applyChangeset", args: ["@check", "@diff"] },
                     { fn: "createChangeset", args: ["@check", "@local", "@left"] },
                     { fn: "changesCount", args: ["@left"] }], ["diff"],
                    guard(finish, function (r) {
                      const ok = r.error === "" && r.results.length === 6 && r.results.every(function (x) { return x.rc === 0; });
                      if (!ok) {
                        // e.g. schema change: geodiff cannot diff, upload the whole file (server rebuilds the diff)
                        client.log("No changeset for " + f.path + " (" + (r.error || JSON.stringify(r.results)) + "), full upload");
                        updated.push({ path: f.path, checksum: f.checksum, size: f.size });
                      } else if (r.results[1].value > 0) {
                        if (r.results[5].value !== 0) {
                          throw new Error(qsTr("Verification of the changes in %1 failed; nothing was uploaded").arg(f.path));
                        }
                        const diffPath = f.path + "-diff-" + Plan.uuid4();
                        const tmp = dir + "/.mergin/" + diffPath;
                        sync.write(tmp, r.outputs["diff"]);
                        state.tmp.push(tmp);
                        const diffSize = r.outputs["diff"].byteLength;
                        updated.push({ path: f.path, checksum: f.originChecksum, size: f.size, diff: { path: diffPath, checksum: sync.sha1(tmp), size: diffSize }, _source: tmp, _uploadSize: diffSize });
                      }
                      nextDiff();
                    }));
        return;
      }
      sync.startPush(state, added, updated, removed, finish);
    });
    nextDiff();
  }

  function startPush(state, added, updated, removed, finish) {
    const dir = state.p.dir;
    if (!added.length && !updated.length && !removed.length) {
      finish(true, state.pulled ? qsTr("Successfully synchronised") : qsTr("Up to date"));
      return;
    }
    const uploads = [];
    const entry = function (f, source, uploadSize) {
      const e = { path: f.path, checksum: f.checksum, size: f.size, chunks: Plan.chunkIds(uploadSize, chunkSize) };
      if (f.diff) e.diff = f.diff;
      uploads.push({ entry: e, source: source, size: uploadSize });
      return e;
    };
    const payload = {
      version: String(state.meta.version),
      changes: {
        added: added.map(function (f) { return entry(f, dir + "/" + f.path, f.size); }),
        updated: updated.map(function (f) { return f._source ? entry(f, f._source, f._uploadSize) : entry(f, dir + "/" + f.path, f.size); }),
        removed: removed.map(function (f) { return { path: f.path, checksum: f.checksum, size: f.size }; })
      }
    };
    statusText = qsTr("Uploading changes");
    progress = 0.6;
    client.log("Push " + state.meta.version + ": " + added.length + " added, " + updated.length + " updated, " + removed.length + " removed");
    const ns = encodeURIComponent(state.p.namespace), name = encodeURIComponent(state.p.name);
    client.authRequest("POST", "v1/project/push/" + ns + "/" + name, payload, guard(finish, function (resp) {
      if (!resp || !resp.transaction) {
        // nothing to upload (e.g. only removals): the server answered with the new project version
        sync.completePush(state, resp, added, updated, removed, finish);
        return;
      }
      const tx = resp.transaction;
      const total = uploads.reduce(function (s, u) { return s + u.size; }, 0) || 1;
      let sent = 0, u = 0;
      const cancel = function (message) {
        client.authRequest("POST", "v1/project/push/cancel/" + tx, undefined, function () {}, function () {});
        finish(false, message);
      };
      const nextUpload = guard(finish, function () {
        if (u >= uploads.length) {
          statusText = qsTr("Finishing upload");
          client.authRequest("POST", "v1/project/push/finish/" + tx, undefined, guard(finish, function (info) {
            sync.completePush(state, info, added, updated, removed, finish);
          }), function (message) { cancel(message); });
          return;
        }
        const up = uploads[u++];
        const bytes = new Uint8Array(sync.read(up.source));
        if (bytes.length !== up.size) { cancel(qsTr("%1 changed during upload").arg(up.entry.path)); return; }
        statusText = qsTr("Uploading %1").arg(up.entry.path);
        let c = 0;
        const nextChunk = function () {
          if (c >= up.entry.chunks.length) { nextUpload(); return; }
          const from = c * chunkSize;
          const chunk = bytes.slice(from, Math.min(from + chunkSize, bytes.length)).buffer;
          const id = up.entry.chunks[c++];
          client.authUpload("v1/project/push/chunk/" + tx + "/" + id, chunk, function () {
            sent += chunk.byteLength;
            progress = 0.6 + 0.35 * sent / total;
            nextChunk();
          }, function (message) { cancel(message); });
        };
        nextChunk();
      });
      nextUpload();
    }), function (message, status) {
      if (status === 400 && /version mismatch/i.test(message) && !state.retried) {
        // somebody pushed in between: pull their version and try once more
        state.retried = true;
        client.log("Server has a newer version, pulling again");
        sync.pullThenPush(state, finish);
        return;
      }
      finish(false, message);
    });
  }

  function completePush(state, info, added, updated, removed, finish) {
    const dir = state.p.dir;
    if (!info || !info.version || !info.files) {
      // older servers answer push/finish without the file list: fetch it
      client.authRequest("GET", "v1/project/" + encodeURIComponent(state.p.namespace) + "/" + encodeURIComponent(state.p.name), undefined,
                         guard(finish, function (fresh) { sync.completePush(state, fresh, added, updated, removed, finish); }),
                         function (message) { finish(false, message); });
      return;
    }
    // base copies now equal what the server has for every pushed GeoPackage
    added.concat(updated).forEach(function (f) {
      if (Plan.isVersioned(f.path)) sync.write(dir + "/.mergin/" + f.path, sync.read(dir + "/" + f.path));
    });
    removed.forEach(function (f) { sync.remove(dir + "/.mergin/" + f.path); });
    writeJson(dir + "/.mergin/mergin.json", info);
    state.meta = info;
    state.pushed = true;
    progress = 1;
    finish(true, qsTr("Successfully synchronised"));
  }
}
