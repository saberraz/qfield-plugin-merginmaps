import QtQuick

// Runs geodiff operations in a WorkerScript so the QField UI stays responsive.
// WorkerScript messages drop ArrayBuffers, so file bytes travel as arrays of 8 KB "binary string" chunks
// (a single multi-MB string message hangs Qt).
Item {
  id: geodiff

  property int _nextId: 1
  // a Map, not an object: deleting/re-adding object keys is the pattern behind the V4 crash QTBUG-147153
  property var _callbacks: new Map()

  // files: { name: ArrayBuffer }, ops: [{ fn, args, allowFailure }], outputs: [names]
  // callback({ results: [{ rc, value, error }], outputs: { name: ArrayBuffer }, error })
  function run(files, ops, outputs, callback) {
    const id = _nextId++;
    _callbacks.set(id, callback);
    const encoded = {};
    for (const name in files) {
      encoded[name] = toChunks(files[name]);
    }
    worker.sendMessage({ id: id, files: encoded, ops: ops, outputs: outputs || [] });
  }

  function toChunks(buffer) {
    const bytes = new Uint8Array(buffer || new ArrayBuffer(0));
    const parts = [];
    for (let i = 0; i < bytes.length; i += 8192) {
      // String.fromCharCode.apply(null, typedArray) returns zeros in Qt's V4: convert to a plain Array first
      parts.push(String.fromCharCode.apply(null, Array.prototype.slice.call(bytes.subarray(i, i + 8192))));
    }
    return parts;
  }

  function fromChunks(parts) {
    let total = 0;
    for (const p of parts) total += p.length;
    const out = new Uint8Array(total);
    let off = 0;
    for (const s of parts) {
      for (let j = 0; j < s.length; j++) out[off++] = s.charCodeAt(j);
    }
    return out.buffer;
  }

  WorkerScript {
    id: worker
    source: "../js/geodiffworker.js"
    onMessage: function (reply) {
      const cb = geodiff._callbacks.get(reply.id);
      geodiff._callbacks.delete(reply.id);
      const outputs = {};
      for (const name in reply.outputs) {
        outputs[name] = geodiff.fromChunks(reply.outputs[name]);
      }
      if (cb) {
        cb({ results: reply.results || [], outputs: outputs, error: reply.error || "" });
      }
    }
  }
}
