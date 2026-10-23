import QtQuick
import QtTest

import "../../plugin/qml"
import "../../plugin/js/merginutils.js" as MerginUtils
import "XhrShim.js" as XhrShim

// Project listing and chunked raw downloads against the local test server (tests/server/*, seeded projects).
TestCase {
  id: tc
  name: "MerginProjectsApi"

  Component {
    id: clientComponent
    MerginClient {
      createRequest: XhrShim.create
      store: MockSettings {}
    }
  }

  SignalSpy { id: loginSpy; signalName: "loginFinished" }

  function loggedInClient() {
    const c = createTemporaryObject(clientComponent, tc);
    c.setServerUrl("http://127.0.0.1:5000");
    loginSpy.clear();
    loginSpy.target = c;
    c.login("fielduser", "Field-Pass-123", false);
    loginSpy.wait(10000);
    verify(c.loggedIn);
    return c;
  }

  function get(c, path) {
    let result = null;
    c.authRequest("GET", path, undefined, function (r) { result = { ok: true, r: r }; }, function (m, s) { result = { ok: false, m: m, s: s }; });
    tryVerify(function () { return result !== null; }, 10000);
    verify(result.ok, JSON.stringify(result));
    return result.r;
  }

  function test_list_projects() {
    const c = loggedInClient();
    const r = get(c, "v1/project/paginated?page=1&per_page=100&order_params=namespace_asc,name_asc");
    const names = r.projects.map(function (p) { return p.namespace + "/" + p.name; });
    verify(names.indexOf("mergin/dummy-points") >= 0, names);
    verify(names.indexOf("mergin/bee-farming") >= 0, names);
    verify(names.indexOf("mergin/wastewater-network") >= 0, names);
    verify(names.indexOf("mergin/dummy-edge-cases") >= 0, names);
  }

  function test_chunked_download_of_big_file_matches_size() {
    const c = loggedInClient();
    const info = get(c, "v1/project/mergin/dummy-edge-cases");
    const file = info.files.filter(function (f) { return f.path === "big/points_big.gpkg"; })[0];
    verify(file.size > MerginUtils.DOWNLOAD_CHUNK_SIZE, "needs more than one chunk");
    const ranges = MerginUtils.chunkRanges(file.size);
    const buffer = new Uint8Array(file.size);
    let done = 0, error = "";
    ranges.forEach(function (range) {
      c.authDownloadRange("v1/project/raw/mergin/dummy-edge-cases", MerginUtils.rawFileQuery(file.path, info.version), range[0], range[1],
        function (data) { buffer.set(new Uint8Array(data), range[0]); done++; }, function (m) { error = m; done++; });
    });
    tryVerify(function () { return done === ranges.length; }, 30000);
    compare(error, "");
    // a GeoPackage is an SQLite file: header magic at the start, and the tail must have been filled too
    compare(MerginUtils.utf8Decode(buffer.slice(0, 15).buffer), "SQLite format 3");
    let tailNonZero = false;
    for (let i = file.size - 4096; i < file.size; i++) if (buffer[i] !== 0) { tailNonZero = true; break; }
    verify(tailNonZero, "last chunk landed at the right offset");
  }

  function test_download_unicode_path() {
    const c = loggedInClient();
    let got = null;
    c.authDownloadRange("v1/project/raw/mergin/dummy-edge-cases", MerginUtils.rawFileQuery("Fotky ščé/photo 1.jpg", "v1"), 0, 4999,
      function (data) { got = data.byteLength; }, function (m, s) { got = "error " + s + " " + m; });
    tryVerify(function () { return got !== null; }, 10000);
    compare(got, 5000);
  }

  function test_download_wrong_range_reports_error() {
    const c = loggedInClient();
    let result = null;
    // asks for more bytes than the file has: must not be reported as success
    c.authDownloadRange("v1/project/raw/mergin/dummy-points", MerginUtils.rawFileQuery("trees.gpkg", "v1"), 0, 10 * 1024 * 1024,
      function () { result = "ok"; }, function (m) { result = "error"; });
    tryVerify(function () { return result !== null; }, 10000);
    compare(result, "error");
  }

  function test_stalled_transfer_times_out() {
    // a socket that accepts but never answers: the watchdog must abort and report failure
    const c = loggedInClient();
    c.transferTimeoutMs = 3000;
    let result = null;
    c.serverUrl = "http://10.255.255.1:9";   // non-routable: the connection hangs (assigned directly to keep the session)
    c.tokenExpiry = "2999-01-01T00:00:00Z";
    c.authDownloadRange("v1/project/raw/x/y", "file=a&version=v1", 0, 9, function () { result = "ok"; }, function (m) { result = "error: " + m; });
    tryVerify(function () { return result !== null; }, 15000);
    compare(result, "error: The connection timed out");
  }
}
