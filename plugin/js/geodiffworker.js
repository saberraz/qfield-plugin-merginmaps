// WorkerScript running geodiff (compiled to JS) off the UI thread. Plain script, not a .pragma library:
// WorkerScript cannot use .import reliably, so geodiff is loaded with Qt.include().
//
// Request:  { id, files: { name: [binary string chunks] }, ops: [ { fn, args: [...] } ], outputs: [names] }
//           file names map to /w/<name> in the module's in-memory filesystem; op args starting with "@" are file
//           names (e.g. "@base.gpkg"), other args are passed as is.
// Reply:    { id, results: [ { rc, value } ], outputs: { name: [chunks] }, error }
// Supported fn: createChangeset(base, modified, out), applyChangeset(db, changeset), rebase(base, their, modified,
//   conflictFile), changesCount(changeset) -> value, listChanges(changeset, json), copy(src, dst).

var gd = null;
var gdCtx = 0;
var CHUNK = 8192;

function toChunks(bytes) {
  var parts = [];
  for (var i = 0; i < bytes.length; i += CHUNK) {
    parts.push(String.fromCharCode.apply(null, Array.prototype.slice.call(bytes.subarray(i, i + CHUNK))));
  }
  return parts;
}

function fromChunks(parts) {
  var total = 0, i, j;
  for (i = 0; i < parts.length; i++) total += parts[i].length;
  var out = new Uint8Array(total), off = 0;
  for (i = 0; i < parts.length; i++) {
    var s = parts[i];
    for (j = 0; j < s.length; j++) out[off++] = s.charCodeAt(j);
  }
  return out;
}

function path(name) { return "/w/" + name; }

function exists(p) {
  try { gd.FS.stat(p); return true; } catch (e) { return false; }
}

// A C++ exception that escapes a geodiff C API call arrives as an Emscripten exception object (not an Error):
// turn it into its message and release it (GEODIFF_changesCount on a truncated changeset in geodiff <= 2.3.2,
// MerginMaps/geodiff#272). Needs geodiff-js >= v2.3.2-js.1, which exports getExceptionMessage.
function describe(e) {
  if (e instanceof Error) return String(e);
  try {
    var m = gd.getExceptionMessage(e);
    gd.decrementExceptionRefcount(e);
    return m.join(": ");
  } catch (e2) {
    return "geodiff internal error: " + e;
  }
}

function call(fn, args) {
  try {
    return callUnchecked(fn, args);
  } catch (e) {
    return { rc: 1, error: describe(e) };
  }
}

function callUnchecked(fn, args) {
  var mapped = args.map(function (a) { return typeof a === "string" && a[0] === "@" ? path(a.substring(1)) : a; });
  switch (fn) {
  case "copy":
    gd.FS.writeFile(mapped[1], gd.FS.readFile(mapped[0]));
    return { rc: 0 };
  case "changesCount": {
    var n = gd.ccall("GEODIFF_changesCount", "number", ["number", "string"], [gdCtx, mapped[0]]);
    return n < 0 ? { rc: 1, error: lastError() } : { rc: 0, value: n };
  }
  default: {
    var rc = gd.ccall("GEODIFF_" + fn, "number", ["number"].concat(mapped.map(function () { return "string"; })), [gdCtx].concat(mapped));
    return rc === 0 ? { rc: 0 } : { rc: rc, error: lastError() };
  }
  }
}

function lastError() {
  return gd.UTF8ToString(gd._GEODIFF_CX_lastError(gdCtx));
}

function clearWorkDir() {
  gd.FS.readdir("/w").forEach(function (n) {
    if (n !== "." && n !== "..") gd.FS.unlink("/w/" + n);
  });
}

function handle(msg) {
  var reply = { id: msg.id, results: [], outputs: {}, error: "" };
  try {
    for (var name in msg.files) {
      gd.FS.writeFile(path(name), fromChunks(msg.files[name]));
    }
    for (var i = 0; i < msg.ops.length; i++) {
      var r = call(msg.ops[i].fn, msg.ops[i].args || []);
      reply.results.push(r);
      if (r.rc !== 0 && !msg.ops[i].allowFailure) break;
    }
    (msg.outputs || []).forEach(function (n) {
      if (exists(path(n))) reply.outputs[n] = toChunks(gd.FS.readFile(path(n)));
    });
  } catch (e) {
    reply.error = describe(e);
  }
  try { clearWorkDir(); } catch (e2) {}
  WorkerScript.sendMessage(reply);
}

WorkerScript.onMessage = function (msg) {
  if (gd) {
    handle(msg);
    return;
  }
  Qt.include("geodiff_inc.js");
  createGeodiff({ print: function () {}, printErr: function () {} }).then(function (m) {
    gd = m;
    gdCtx = gd._GEODIFF_createContext();
    gd.FS.mkdir("/w");
    handle(msg);
  }).catch(function (e) {
    WorkerScript.sendMessage({ id: msg.id, results: [], outputs: {}, error: "geodiff failed to load: " + e });
  });
};
