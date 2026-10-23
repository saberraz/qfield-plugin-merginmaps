import QtQuick
import QtTest

import "../../plugin/js/merginutils.js" as MerginUtils

TestCase {
  name: "MerginUtils"

  function test_normaliseServerUrl() {
    compare(MerginUtils.normaliseServerUrl(""), "https://app.merginmaps.com");
    compare(MerginUtils.normaliseServerUrl("  my.server.org/ "), "https://my.server.org");
    compare(MerginUtils.normaliseServerUrl("http://127.0.0.1:5000//"), "http://127.0.0.1:5000");
    compare(MerginUtils.joinUrl("https://a.b/", "/v1/auth/login"), "https://a.b/v1/auth/login");
  }

  function test_parseIsoDate_data() {
    return [
      { tag: "python microseconds +00:00", value: "2026-10-22T23:41:14.335865+00:00", expected: Date.UTC(2026, 9, 22, 23, 41, 14, 335) },
      { tag: "Z, millis", value: "2019-05-04T14:21:56.695Z", expected: Date.UTC(2019, 4, 4, 14, 21, 56, 695) },
      { tag: "no fraction, no zone (UTC)", value: "2026-01-02T03:04:05", expected: Date.UTC(2026, 0, 2, 3, 4, 5) },
      { tag: "positive offset", value: "2026-01-02T03:04:05+02:00", expected: Date.UTC(2026, 0, 2, 1, 4, 5) },
      { tag: "negative offset no colon", value: "2026-01-02T03:04:05-0130", expected: Date.UTC(2026, 0, 2, 4, 34, 5) },
      { tag: "space separator", value: "2026-01-02 03:04:05Z", expected: Date.UTC(2026, 0, 2, 3, 4, 5) }
    ];
  }

  function test_parseIsoDate(data) {
    compare(MerginUtils.parseIsoDate(data.value), data.expected);
  }

  function test_parseIsoDate_invalid() {
    verify(isNaN(MerginUtils.parseIsoDate("")));
    verify(isNaN(MerginUtils.parseIsoDate("yesterday")));
    verify(isNaN(MerginUtils.parseIsoDate(undefined)));
    verify(isNaN(MerginUtils.parseIsoDate(12345)));
  }

  function test_tokenNeedsRenewal() {
    const now = Date.UTC(2026, 9, 22, 12, 0, 0);
    verify(MerginUtils.tokenNeedsRenewal("", "2026-10-23T12:00:00Z", now), "missing token");
    verify(MerginUtils.tokenNeedsRenewal("t", "", now), "missing expiry");
    verify(MerginUtils.tokenNeedsRenewal("t", "garbage", now), "unparsable expiry");
    verify(MerginUtils.tokenNeedsRenewal("t", "2026-10-22T11:00:00Z", now), "expired");
    verify(MerginUtils.tokenNeedsRenewal("t", "2026-10-22T12:04:00Z", now), "inside the 5 min margin");
    verify(!MerginUtils.tokenNeedsRenewal("t", "2026-10-22T12:06:00Z", now), "outside the margin");
    verify(!MerginUtils.tokenNeedsRenewal("t", "2026-10-23T00:00:00.123456+00:00", now), "server format");
  }

  function test_sessionFromLoginResponse() {
    const nested = MerginUtils.sessionFromLoginResponse({ username: "u", email: "e@x", session: { token: "tok", expire: "2026-01-01T00:00:00Z" } });
    compare(nested.token, "tok");
    compare(nested.expire, "2026-01-01T00:00:00Z");
    compare(nested.username, "u");
    compare(nested.email, "e@x");
    const top = MerginUtils.sessionFromLoginResponse({ username: "u", token: "tok2", expire: "x" });
    compare(top.token, "tok2");
    compare(MerginUtils.sessionFromLoginResponse({ username: "u" }), null);
    compare(MerginUtils.sessionFromLoginResponse(null), null);
    compare(MerginUtils.sessionFromLoginResponse("html"), null);
  }

  function test_serverInfoFromConfig() {
    const info = MerginUtils.serverInfoFromConfig({ major: 2025, minor: 6, fix: 2, version: "2025.6.2", sso_enabled: true, server_type: "ce" });
    compare(info.version, "2025.6.2");
    compare(info.ssoEnabled, true);
    compare(info.serverType, "ce");
    compare(MerginUtils.serverInfoFromConfig({ major: 2025, minor: 1 }).version, "2025.1.0");
    compare(MerginUtils.serverInfoFromConfig({ service: "something else" }), null);
    compare(MerginUtils.serverInfoFromConfig("<html>"), null);
  }

  function test_errorMessage() {
    compare(MerginUtils.errorMessage({ detail: "Invalid username or password" }, "f"), "Invalid username or password");
    compare(MerginUtils.errorMessage("x".repeat(400), "fallback"), "fallback");
    compare(MerginUtils.errorMessage(undefined, "fallback"), "fallback");
  }

  function test_chunkRanges() {
    compare(MerginUtils.chunkRanges(0, 10), []);
    compare(MerginUtils.chunkRanges(10, 10), [[0, 9]]);
    compare(MerginUtils.chunkRanges(25, 10), [[0, 9], [10, 19], [20, 24]]);
    compare(MerginUtils.chunkRanges(14131200).length, 2, "14 MB in 10 MB chunks");
  }

  function test_hexFromBuffer() {
    compare(MerginUtils.hexFromBuffer(new Uint8Array([0, 1, 15, 16, 171, 255]).buffer), "00010f10abff");
    compare(MerginUtils.hexFromBuffer(null), "");
  }

  function test_isSafeRelativePath_data() {
    return [
      { tag: "simple", path: "trees.gpkg", ok: true },
      { tag: "nested unicode", path: "Fotky ščé/photo 1.jpg", ok: true },
      { tag: "ampersand parens", path: "data/trees & shrubs (2026).gpkg", ok: true },
      { tag: "dotfile", path: ".hidden.txt", ok: true },
      { tag: "parent", path: "../other/x.gpkg", ok: false },
      { tag: "inner parent", path: "a/../../x", ok: false },
      { tag: "absolute", path: "/etc/passwd", ok: false },
      { tag: "windows drive", path: "C:/x", ok: false },
      { tag: "backslash parent", path: "a\\..\\..\\x", ok: false },
      { tag: "empty segment", path: "a//b", ok: false },
      { tag: "empty", path: "", ok: false }
    ];
  }

  function test_isSafeRelativePath(data) {
    compare(MerginUtils.isSafeRelativePath(data.path), data.ok);
  }

  function test_isSafeName() {
    verify(MerginUtils.isSafeName("bee-farming"));
    verify(!MerginUtils.isSafeName(".."));
    verify(!MerginUtils.isSafeName("a/b"));
    verify(!MerginUtils.isSafeName(""));
  }

  function test_findProjectFile() {
    compare(MerginUtils.findProjectFile([{ path: "a.gpkg" }, { path: "proj.qgz" }]), "proj.qgz");
    compare(MerginUtils.findProjectFile([{ path: "sub/x.qgs" }, { path: "z.qgs" }, { path: "a.QGS" }]), "a.QGS");
    compare(MerginUtils.findProjectFile([{ path: "sub/x.qgs" }]), "", "only root-level project files count");
  }

  function test_rawFileQuery() {
    compare(MerginUtils.rawFileQuery("data/trees & shrubs (2026).gpkg", "v3"), "file=data%2Ftrees%20%26%20shrubs%20(2026).gpkg&version=v3");
    compare(MerginUtils.rawFileQuery("Fotky ščé/a+b.jpg", "v1"), "file=Fotky%20%C5%A1%C4%8D%C3%A9%2Fa%2Bb.jpg&version=v1");
  }

  function test_utf8_roundtrip() {
    const samples = ["", "ascii", "ščé Ž", "中文", "emoji 🗺️📍", JSON.stringify({ path: "Fotky ščé/photo 1.jpg" })];
    for (const s of samples) {
      compare(MerginUtils.utf8Decode(MerginUtils.utf8Encode(s)), s, s);
    }
    compare(MerginUtils.hexFromBuffer(MerginUtils.utf8Encode("š🗺")), "c5a1f09f97ba");
  }

  function test_signUpAndResetUrls() {
    const saas = MerginUtils.serverInfoFromConfig({ major: 2026, minor: 10, server_type: "saas", user_self_registration: true });
    compare(saas.serverType, "saas");
    verify(saas.userSelfRegistration);
    verify(!MerginUtils.serverInfoFromConfig({ major: 2025, minor: 6, server_type: "ce" }).userSelfRegistration);
    // hosted: the dashboard's registration page, also before /config has answered
    compare(MerginUtils.signUpUrl("https://app.merginmaps.com", "saas", true), "https://app.merginmaps.com/register");
    compare(MerginUtils.signUpUrl("https://app.merginmaps.com/", "", false), "https://app.merginmaps.com/register");
    // Enterprise with self-registration: the server (as mobile does); without it, or Community Edition: no sign up
    compare(MerginUtils.signUpUrl("https://mergin.example.org", "ee", true), "https://mergin.example.org");
    compare(MerginUtils.signUpUrl("https://mergin.example.org", "ee", false), "");
    compare(MerginUtils.signUpUrl("http://127.0.0.1:5000", "ce", false), "");
    compare(MerginUtils.signUpUrl("http://127.0.0.1:5000", "", false), "", "unknown custom server");
    compare(MerginUtils.resetPasswordUrl("https://app.merginmaps.com"), "https://app.merginmaps.com/login/reset");
  }
}
