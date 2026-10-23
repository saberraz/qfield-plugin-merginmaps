.pragma library

// Pure planning helpers for Mergin sync, mirroring the official mergin-client (merginproject.py / utils.py).
// File entries are {path, checksum, size}. No I/O here.

// Files that are never synced: Mergin's metadata folder, SQLite side files, editor junk and QField's project thumbnails.
function isIgnored(path) {
  if (path === ".mergin" || path.indexOf(".mergin/") === 0) {
    return true;
  }
  var name = path.substring(path.lastIndexOf("/") + 1);
  if (name === ".DS_Store" || name === ".directory") {
    return true;
  }
  if (/(-shm|-wal|~|\.pyc|\.swap)$/.test(name)) {
    return true;
  }
  // QField writes "<project>.qgz.png" / "<project>.qgs.png" thumbnails next to every project it opens
  return /\.(qgs|qgz)\.png$/i.test(name);
}

// Files geodiff can diff/rebase (Mergin "versioned" files).
function isVersioned(path) {
  return /\.(gpkg|sqlite)$/i.test(path);
}

function isQgisProject(path) {
  return /\.(qgs|qgz)$/i.test(path);
}

function toMap(files) {
  var m = {};
  files.forEach(function (f) { m[f.path] = f; });
  return m;
}

// Local changes since the last sync: origin = metadata files, current = files found on disk (with checksums).
// Like mergin-client, a versioned file whose checksum differs is only a *candidate* update: geodiff decides later.
function compareFileSets(origin, current) {
  var o = toMap(origin), c = toMap(current);
  var added = current.filter(function (f) { return !o[f.path]; });
  var removed = origin.filter(function (f) { return !c[f.path]; });
  var updated = current.filter(function (f) { return o[f.path] && o[f.path].checksum !== f.checksum; })
                       .map(function (f) { return { path: f.path, checksum: f.checksum, size: f.size, originChecksum: o[f.path].checksum }; });
  return { added: added, removed: removed, updated: updated };
}

// What the server changed since our local version: metadata files vs. server files.
function serverChanges(metaFiles, serverFiles) {
  return compareFileSets(metaFiles, serverFiles);
}

function splitName(path) {
  var slash = path.lastIndexOf("/");
  var head = slash >= 0 ? path.substring(0, slash + 1) : "";
  var tail = path.substring(slash + 1);
  var dot = tail.indexOf(".");                 // all suffixes, like pathlib's "".join(suffixes)
  if (dot <= 0) {
    return { head: head, name: tail, ext: "" };
  }
  return { head: head, name: tail.substring(0, dot), ext: tail.substring(dot) };
}

// "<name> (conflicted copy, <user> v<N>).<ext>"; QGIS project files get a "~" so a project never has two .qgs files.
function conflictedCopyName(path, user, version) {
  var p = splitName(path);
  var ext = p.ext + (isQgisProject(path) ? "~" : "");
  return p.head + p.name + " (conflicted copy, " + user + " v" + version + ")" + ext;
}

// "<name> (edit conflict, <user> v<N>).json" written next to a GeoPackage when rebase found conflicting edits.
function editConflictName(path, user, version) {
  var p = splitName(path);
  return p.head + p.name + " (edit conflict, " + user + " v" + version + ").json";
}

// Appends " (1)", " (2)"... before the extension until `exists(name)` is false.
function uniquePath(path, exists) {
  if (!exists(path)) {
    return path;
  }
  var p = splitName(path);
  for (var i = 1; i < 1000; i++) {
    var candidate = p.head + p.name + " (" + i + ")" + p.ext;
    if (!exists(candidate)) {
      return candidate;
    }
  }
  return path;
}

function versionNumber(version) {
  var n = parseInt(String(version).replace(/^v/, ""), 10);
  return isNaN(n) ? 0 : n;
}

// Random UUID v4 for upload chunk ids (Math.random is fine: ids only need to be unique within a transaction).
function uuid4() {
  var hex = "0123456789abcdef";
  var s = "";
  for (var i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      s += "-";
    } else if (i === 14) {
      s += "4";
    } else if (i === 19) {
      s += hex[(Math.random() * 4 | 0) + 8];
    } else {
      s += hex[Math.random() * 16 | 0];
    }
  }
  return s;
}

function chunkIds(size, chunkSize) {
  var n = Math.max(1, Math.ceil(size / chunkSize));
  var ids = [];
  for (var i = 0; i < n; i++) {
    ids.push(uuid4());
  }
  return size === 0 ? [] : ids;
}
