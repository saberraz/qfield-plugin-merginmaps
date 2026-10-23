import QtQuick

import org.qfield

import "../js/merginutils.js" as MerginUtils

// Remote project list, projects on this device and project downloads.
//
// QField plugins may only write inside the folder of the currently open project, and may only delete folders that
// sit directly in "Created Projects" (QfFileUtils::isDeletable). Each Mergin project therefore gets its own folder,
// created with QfProjectUtils.createProject, which also writes a small empty stub project into it:
//   <QField>/Created Projects/mm_<workspace>_<project>/mm_<workspace>_<project>.qgz   (stub, never synchronised)
//   <QField>/Created Projects/mm_<workspace>_<project>/...                           (the Mergin project's files)
// Loading the stub makes the folder writable and releases the project's GeoPackages (sync needs both); the folder
// can be removed as a whole. A separate "home" stub (Created Projects/Mergin_Maps) is loaded while a project folder
// is deleted. Projects downloaded by plugin 0.4 live under the home stub (Mergin_Maps/projects/<ws>/<name>) and
// keep working, but cannot be removed.
//
// A finished download contains .mergin/mergin.json (project metadata, same format as the official clients) and a
// .mergin/<path> base copy of every GeoPackage. Completeness is tracked in the settings registry: the version is
// cleared when a download starts and set once mergin.json (written last) is in place. (Plugins cannot delete or,
// outside the open project, inspect the marker file, so it cannot carry that state itself.)
Item {
  id: projects

  property MerginClient client
  // Active workspace name (MerginWorkspaces.activeName): the server list shows only this workspace's projects
  property string workspace: ""

  // Remote projects of the active workspace: [{namespace, name, version, size, updated, downloaded, localVersion}]
  property var remoteProjects: []
  // Projects on this device, kept in settings: [{server, namespace, name, dir, stub, version, size, updated}].
  // version is "" until the first download completes; dir/stub are absent for 0.4 downloads (home stub layout).
  property var localProjects: []
  property bool listing: false
  property string listError: ""

  // Download state
  property bool downloading: false
  property string activeProject: ""     // "<namespace>/<name>" being downloaded
  property real progress: 0             // 0..1 over all bytes of the project
  property string progressText: ""

  readonly property string homeKey: client ? client.settingsPrefix + "homeProject" : ""
  readonly property string localProjectsKey: client ? client.settingsPrefix + "localProjects" : ""

  signal downloadFinished(bool ok, string fullName, string message)

  Component.onCompleted: loadLocalProjects()

  // ---- local storage ----

  function homeProjectPath() {
    const path = client.store ? client.store.value(homeKey, "") : "";
    return path !== "" && QfFileUtils.fileExists(path) ? path : "";
  }

  function homeDir() {
    const path = homeProjectPath();
    return path ? MerginUtils.directoryOf(path) : "";
  }

  // 0.4 layout: <home>/projects/<namespace>/<name>
  function legacyDir(namespace, name) {
    const home = homeDir();
    return home ? home + "/projects/" + namespace + "/" + name : "";
  }

  function localDir(namespace, name) {
    const entry = findLocal(namespace, name);
    if (entry && entry.dir) return entry.dir;
    const legacy = legacyDir(namespace, name);
    return legacy !== "" && hasMetadata(legacy) ? legacy : "";
  }

  // QfFileUtils.fileExists() is false for folders (and, unlike getFileInfo(), works outside the open project);
  // a project folder is identified by its metadata file
  function hasMetadata(dir) {
    return QfFileUtils.fileExists(dir + "/.mergin/mergin.json");
  }

  function isDownloaded(namespace, name) {
    const entry = findLocal(namespace, name);
    if (entry && entry.dir) return entry.version !== "" && hasMetadata(entry.dir);
    const dir = localDir(namespace, name);
    return dir !== "" && hasMetadata(dir);
  }

  // {namespace, name, dir, stub} of a project on this device (stub is "" for the 0.4 layout)
  function localProject(namespace, name) {
    const entry = findLocal(namespace, name);
    if (entry && entry.dir) return { namespace: namespace, name: name, dir: entry.dir, stub: entry.stub };
    return { namespace: namespace, name: name, dir: legacyDir(namespace, name), stub: "" };
  }

  // The Mergin project a file belongs to: {namespace, name, dir, stub} (stub is "" for the 0.4 layout), or null.
  function projectForPath(path) {
    if (!path) return null;
    for (let i = 0; i < localProjects.length; i++) {
      const e = localProjects[i];
      if (e.dir && path.indexOf(e.dir + "/") === 0) return { namespace: e.namespace, name: e.name, dir: e.dir, stub: e.stub };
    }
    const home = homeDir();
    const prefix = home + "/projects/";
    if (!home || path.indexOf(prefix) !== 0) return null;
    const parts = path.substring(prefix.length).split("/");
    if (parts.length < 3) return null;
    return { namespace: parts[0], name: parts[1], dir: prefix + parts[0] + "/" + parts[1], stub: "" };
  }

  // Local version of each downloaded project, kept in settings: other projects' .mergin/mergin.json are outside the
  // sandbox while a different project is open.
  function localVersion(namespace, name) {
    return client.store ? String(client.store.value(client.settingsPrefix + "localVersion/" + namespace + "/" + name, "")) : "";
  }

  function setLocalVersion(namespace, name, version) {
    if (client.store) client.store.setValue(client.settingsPrefix + "localVersion/" + namespace + "/" + name, String(version));
    remoteProjects = remoteProjects.map(function (p) {
      if (p.namespace === namespace && p.name === name) p.localVersion = String(version);
      return p;
    });
    if (findLocal(namespace, name)) registerLocal(namespace, name, { version: String(version), updated: new Date().toISOString() });
  }

  // ---- projects on this device ----

  function loadLocalProjects() {
    let list = [];
    try {
      list = JSON.parse(client.store ? String(client.store.value(localProjectsKey, "[]")) : "[]");
    } catch (e) {
      list = [];
    }
    // drop entries whose folder is gone (removed outside the plugin)
    localProjects = (Array.isArray(list) ? list : []).filter(function (p) {
      return p.stub ? QfFileUtils.fileExists(p.stub) : hasMetadata(legacyDir(p.namespace, p.name));
    });
  }

  function _saveLocalProjects(list) {
    list.sort(function (a, b) { return (a.namespace + "/" + a.name).localeCompare(b.namespace + "/" + b.name); });
    localProjects = list;
    if (client.store) client.store.setValue(localProjectsKey, JSON.stringify(list));
  }

  function findLocal(namespace, name) {
    for (let i = 0; i < localProjects.length; i++) {
      if (localProjects[i].namespace === namespace && localProjects[i].name === name) return localProjects[i];
    }
    return null;
  }

  // Adds or updates a project on this device; fields: dir, stub, version, size, updated.
  function registerLocal(namespace, name, fields) {
    const existing = findLocal(namespace, name);
    const entry = { server: client.serverUrl, namespace: namespace, name: name, version: "", size: 0, updated: "" };
    if (existing) for (const k in existing) entry[k] = existing[k];
    for (const k in fields) entry[k] = fields[k];
    _saveLocalProjects(localProjects.filter(function (p) { return p !== existing; }).concat([entry]));
    return entry;
  }

  // The project's own folder and stub, created on first use.
  function prepareProjectFolder(namespace, name) {
    const entry = findLocal(namespace, name);
    if (entry && entry.stub && QfFileUtils.fileExists(entry.stub)) return entry;
    if (entry && !entry.stub && hasMetadata(legacyDir(namespace, name))) return entry;   // 0.4 layout
    const stub = QfProjectUtils.createProject({ "title": "mm " + namespace + " " + name, "basemap": "blank" });
    if (!stub) return null;
    client.log("Created project folder " + MerginUtils.directoryOf(stub));
    return registerLocal(namespace, name, { dir: MerginUtils.directoryOf(stub), stub: stub });
  }

  // Loads the project's stub: the folder becomes writable and the project's files are released.
  function withProjectReleased(project, callback) {
    if (!project.stub) {
      withHomeLoaded(callback);
      return;
    }
    loadProject(project.stub, function () {
      callback(qgisProject.fileName === project.stub, qsTr("Could not open the project folder"));
    });
  }

  // Deletes the local copy (data, base copies and metadata). Local changes that were not synchronised are lost.
  function removeFromDevice(namespace, name, callback) {
    const fullName = MerginUtils.projectFullName(namespace, name);
    const entry = findLocal(namespace, name);
    if (!entry) {
      if (callback) callback(false, qsTr("%1 is not on this device").arg(name));
      return;
    }
    if (!entry.dir) {
      if (callback) callback(false, qsTr("Projects downloaded with version 0.4 of the plugin cannot be removed by it."));
      return;
    }
    // open the (empty) home stub so nothing in the project folder is in use
    withHomeLoaded(function (ok, message) {
      if (!ok) {
        if (callback) callback(false, message);
        return;
      }
      const result = QfFileUtils.deleteFiles([entry.dir]);
      if (!result[entry.dir]) {
        client.log("Could not remove " + fullName + " from " + entry.dir);
        if (callback) callback(false, qsTr("Could not remove the project folder"));
        return;
      }
      if (client.store) client.store.remove(client.settingsPrefix + "localVersion/" + namespace + "/" + name);
      _saveLocalProjects(localProjects.filter(function (p) { return p !== entry; }));
      remoteProjects = remoteProjects.map(function (p) {
        if (p.namespace === namespace && p.name === name) {
          p.downloaded = false;
          p.localVersion = "";
        }
        return p;
      });
      client.log("Removed " + fullName + " from the device");
      if (callback) callback(true, qsTr("Removed %1 from the device").arg(name));
    });
  }

  function ensureHomeProject() {
    let path = homeProjectPath();
    if (path === "") {
      path = QfProjectUtils.createProject({ "title": "Mergin Maps", "basemap": "blank" });
      if (!path) {
        return "";
      }
      client.store.setValue(homeKey, path);
      client.log("Created home project " + path);
    }
    return path;
  }

  property var _onProjectLoaded: null

  Connections {
    target: iface
    function onLoadProjectEnded(path, name) {
      if (projects._onProjectLoaded) {
        const cb = projects._onProjectLoaded;
        projects._onProjectLoaded = null;
        cb(path);
      }
    }
  }

  // Loads a project and calls back once QField has finished (or immediately if it is already open).
  function loadProject(path, callback) {
    if (qgisProject.fileName === path) {
      callback(path);
      return;
    }
    _onProjectLoaded = callback;
    iface.loadFile(path);
  }

  // Makes the home folder writable: the current project must be the home stub.
  function withHomeLoaded(callback) {
    const home = ensureHomeProject();
    if (!home) {
      callback(false, qsTr("Could not create the local Mergin Maps folder"));
      return;
    }
    loadProject(home, function () {
      callback(qgisProject.fileName === home, qsTr("Could not open the local Mergin Maps folder"));
    });
  }

  // ---- remote list ----

  // Lists the active workspace's projects; search is matched on the server against project names.
  function refresh(search) {
    listing = true;
    listError = "";
    let query = "page=1&per_page=100&order_params=namespace_asc,name_asc";
    if (workspace !== "") query += "&only_namespace=" + encodeURIComponent(workspace);
    if (search) query += "&name=" + encodeURIComponent(search);
    const requested = workspace;
    client.authRequest("GET", "v1/project/paginated?" + query, undefined, function (response) {
      if (requested !== workspace) return;   // workspace switched while listing; a newer refresh is on its way
      listing = false;
      const list = (response && response.projects) ? response.projects : [];
      remoteProjects = list.map(function (p) {
        return {
          namespace: String(p.namespace), name: String(p.name), version: String(p.version || ""),
          size: Number(p.disk_usage || 0), updated: String(p.updated || ""),
          downloaded: isDownloaded(String(p.namespace), String(p.name)),
          localVersion: localVersion(String(p.namespace), String(p.name))
        };
      });
      // projects downloaded before the local registry existed
      remoteProjects.forEach(function (p) {
        if (p.downloaded && !findLocal(p.namespace, p.name)) registerLocal(p.namespace, p.name, { version: p.localVersion, size: p.size, updated: p.updated });
      });
      if (response && response.count > list.length) {
        client.log("Showing " + list.length + " of " + response.count + " projects");
      }
    }, function (message) {
      if (requested !== workspace) return;
      listing = false;
      listError = message;
    });
  }

  function markDownloaded(fullName) {
    remoteProjects = remoteProjects.map(function (p) {
      if (MerginUtils.projectFullName(p.namespace, p.name) === fullName) {
        p.downloaded = true;
      }
      return p;
    });
  }

  // ---- open / download ----

  function openLocal(namespace, name, opened) {
    const project = localProject(namespace, name);
    const dir = project.dir;
    const meta = dir + "/.mergin/mergin.json";
    // mergin.json lives inside the project folder; read it with the project's stub loaded so the sandbox allows it
    withProjectReleased(project, function (ok, message) {
      if (!ok) {
        downloadFinished(false, MerginUtils.projectFullName(namespace, name), message);
        return;
      }
      let info = null;
      try {
        info = JSON.parse(MerginUtils.utf8Decode(QfFileUtils.readFileContent(meta)));
      } catch (e) {
        info = null;
      }
      const projectFile = info ? MerginUtils.findProjectFile(info.files || []) : "";
      if (!projectFile) {
        downloadFinished(false, MerginUtils.projectFullName(namespace, name), qsTr("No QGIS project file found in this project"));
        return;
      }
      loadProject(dir + "/" + projectFile, function () { if (opened) opened(); });
    });
  }

  function download(namespace, name) {
    const fullName = MerginUtils.projectFullName(namespace, name);
    if (downloading) {
      return;
    }
    if (!MerginUtils.isSafeName(namespace) || !MerginUtils.isSafeName(name)) {
      downloadFinished(false, fullName, qsTr("Unsupported project name"));
      return;
    }
    downloading = true;
    activeProject = fullName;
    progress = 0;
    progressText = qsTr("Fetching project information…");

    const fail = function (message) {
      client.log("Download of " + fullName + " failed: " + message);
      downloading = false;
      progressText = "";
      downloadFinished(false, fullName, message);
    };

    client.authRequest("GET", "v1/project/" + encodeURIComponent(namespace) + "/" + encodeURIComponent(name), undefined, function (info) {
      const files = (info && info.files) ? info.files : [];
      const unsafe = files.filter(function (f) { return !MerginUtils.isSafeRelativePath(f.path) || f.path.indexOf(".mergin/") === 0; });
      if (unsafe.length) {
        fail(qsTr("The project contains an invalid file path: %1").arg(unsafe[0].path));
        return;
      }
      const projectFile = MerginUtils.findProjectFile(files);
      if (!projectFile) {
        fail(qsTr("No QGIS project file (.qgz/.qgs) in this project"));
        return;
      }
      progressText = qsTr("Preparing local folder…");
      if (!prepareProjectFolder(namespace, name)) {
        fail(qsTr("Could not create the project folder"));
        return;
      }
      const project = localProject(namespace, name);
      const dir = project.dir;
      if (project.stub && files.some(function (f) { return dir + "/" + f.path === project.stub; })) {
        fail(qsTr("The project contains a file that clashes with the plugin's folder stub: %1").arg(MerginUtils.fileNameOf(project.stub)));
        return;
      }
      withProjectReleased(project, function (ok, message) {
        if (!ok) {
          fail(message);
          return;
        }
        // not complete until mergin.json is written: a crash mid-download must not leave a "complete" copy
        registerLocal(namespace, name, { version: "" });
        _downloadFiles(info, files, dir, function (error) {
          if (error) {
            fail(error);
            return;
          }
          if (!QfFileUtils.writeFileContent(dir + "/.mergin/mergin.json", MerginUtils.utf8Encode(JSON.stringify(info)))) {
            fail(qsTr("Could not write project metadata"));
            return;
          }
          client.log("Downloaded " + fullName + " " + info.version + " (" + files.length + " files)");
          markDownloaded(fullName);
          registerLocal(namespace, name, { version: String(info.version), size: Number(info.disk_usage || 0), updated: String(info.updated || "") });
          setLocalVersion(namespace, name, info.version);
          progress = 1;
          progressText = qsTr("Opening project…");
          loadProject(dir + "/" + projectFile, function () {
            downloading = false;
            progressText = "";
            downloadFinished(true, fullName, qsTr("Downloaded %1").arg(name));
          });
        });
      });
    }, function (message) {
      fail(message);
    });
  }

  // Downloads files one after another in DOWNLOAD_CHUNK_SIZE ranges, verifies each SHA-1 and writes base copies of
  // GeoPackages. A file is assembled in memory and written once (QfFileUtils has no append).
  function _downloadFiles(info, files, dir, done) {
    const total = files.reduce(function (sum, f) { return sum + Number(f.size || 0); }, 0);
    let completed = 0;
    let index = 0;
    const version = String(info.version);
    const path = "v1/project/raw/" + encodeURIComponent(info.namespace) + "/" + encodeURIComponent(info.name);

    const nextFile = function () {
      if (index >= files.length) {
        done("");
        return;
      }
      const file = files[index++];
      const size = Number(file.size || 0);
      const ranges = MerginUtils.chunkRanges(size);
      const buffer = new Uint8Array(size);
      let r = 0;
      let retried = false;
      progressText = qsTr("Downloading %1 (%2 of %3)").arg(file.path).arg(index).arg(files.length);

      const finishFile = function () {
        const target = dir + "/" + file.path;
        if (!QfFileUtils.writeFileContent(target, buffer.buffer)) {
          done(qsTr("Could not write %1").arg(file.path));
          return;
        }
        const checksum = MerginUtils.hexFromBuffer(QfFileUtils.fileChecksum(target, 2 /* QCryptographicHash::Sha1 */));
        if (file.checksum && checksum !== String(file.checksum).toLowerCase()) {
          if (!retried) {
            retried = true;
            client.log("Checksum mismatch for " + file.path + ", retrying once");
            r = 0;
            completed -= size;
            nextChunk();
            return;
          }
          done(qsTr("Checksum mismatch for %1").arg(file.path));
          return;
        }
        if (MerginUtils.isGeoPackage(file.path) && !QfFileUtils.writeFileContent(dir + "/.mergin/" + file.path, buffer.buffer)) {
          done(qsTr("Could not write the base copy of %1").arg(file.path));
          return;
        }
        Qt.callLater(nextFile);
      };

      const nextChunk = function () {
        if (r >= ranges.length) {
          finishFile();
          return;
        }
        const range = ranges[r++];
        client.authDownloadRange(path, MerginUtils.rawFileQuery(file.path, version), range[0], range[1], function (data) {
          buffer.set(new Uint8Array(data), range[0]);
          completed += data.byteLength;
          progress = total > 0 ? completed / total : 1;
          nextChunk();
        }, function (message) {
          done(qsTr("%1: %2").arg(file.path).arg(message));
        });
      };
      nextChunk();
    };
    nextFile();
  }
}
