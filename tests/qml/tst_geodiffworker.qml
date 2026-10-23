import QtQuick
import QtTest

import "../../plugin/qml"

// GeodiffWorker (geodiff compiled to JS in a WorkerScript) against pygeodiff reference output.
// Needs QML_XHR_ALLOW_FILE_READ=1 (tests read fixtures from tests/qml/data).
TestCase {
  id: tc
  name: "GeodiffWorker"
  when: windowShown

  GeodiffWorker { id: worker }

  function read(name) {
    const x = new XMLHttpRequest();
    x.open("GET", Qt.resolvedUrl("data/" + name), false);
    x.responseType = "arraybuffer";
    x.send();
    return x.response;
  }

  function runSync(files, ops, outputs) {
    let result = null;
    worker.run(files, ops, outputs, function (r) { result = r; });
    tryVerify(function () { return result !== null; }, 60000);
    return result;
  }

  function bytesEqual(a, b) {
    const x = new Uint8Array(a), y = new Uint8Array(b);
    if (x.length !== y.length) return false;
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
    return true;
  }

  function test_createChangeset_matches_pygeodiff() {
    const r = runSync({ "base.gpkg": read("base5k.gpkg"), "local.gpkg": read("local5k.gpkg") },
                      [{ fn: "createChangeset", args: ["@base.gpkg", "@local.gpkg", "@d.bin"] }, { fn: "changesCount", args: ["@d.bin"] }],
                      ["d.bin"]);
    compare(r.error, "");
    compare(r.results[0].rc, 0);
    compare(r.results[1].value, 1655);   // pygeodiff changes_count of the same pair
    verify(bytesEqual(r.outputs["d.bin"], read("local5k_ref.diff")), "byte-identical to pygeodiff");
  }

  function test_rebase_and_verify_roundtrip() {
    // pull-with-local-edits path: rebase local onto their, then the rebased file must contain their changes
    const r = runSync({ "base.gpkg": read("base5k.gpkg"), "their.gpkg": read("their5k.gpkg"), "local.gpkg": read("local5k.gpkg") },
                      [{ fn: "rebase", args: ["@base.gpkg", "@their.gpkg", "@local.gpkg", "@conflicts.json"] },
                       { fn: "createChangeset", args: ["@their.gpkg", "@local.gpkg", "@mine.bin"] },
                       { fn: "copy", args: ["@their.gpkg", "@check.gpkg"] },
                       { fn: "applyChangeset", args: ["@check.gpkg", "@mine.bin"] },
                       { fn: "createChangeset", args: ["@check.gpkg", "@local.gpkg", "@left.bin"] },
                       { fn: "changesCount", args: ["@left.bin"] }],
                      ["local.gpkg", "conflicts.json"]);
    compare(r.error, "");
    for (let i = 0; i < r.results.length; i++) compare(r.results[i].rc, 0, "op " + i + " " + (r.results[i].error || ""));
    compare(r.results[5].value, 0, "their + rebased local changes reproduce the rebased file");
    verify(r.outputs["local.gpkg"].byteLength > 0);
    verify(r.outputs["conflicts.json"] !== undefined, "this fixture has conflicting edits");
  }

  function test_failure_is_reported_not_thrown() {
    const r = runSync({ "x.gpkg": new ArrayBuffer(10) }, [{ fn: "createChangeset", args: ["@x.gpkg", "@x.gpkg", "@d.bin"] }], []);
    verify(r.results[0].rc !== 0);
    verify(r.results[0].error.length > 0, r.results[0].error);
  }

  function test_worker_state_is_clean_between_runs() {
    const r = runSync({}, [{ fn: "changesCount", args: ["@d.bin"] }], ["d.bin"]);
    verify(r.results[0].rc !== 0, "files from previous runs must not leak");
  }
}
