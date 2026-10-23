import QtQuick
import QtTest

import "../../plugin/qml"
import "XhrShim.js" as XhrShim

// Integration tests for MerginClient authentication against a real Mergin server.
// Expects tests/server/start_local_mergin.sh (server at http://127.0.0.1:5000, user fielduser / Field-Pass-123).
TestCase {
  id: tc
  name: "MerginAuth"

  readonly property string serverUrl: "http://127.0.0.1:5000"
  readonly property string user: "fielduser"
  readonly property string userEmail: "field@example.com"
  readonly property string pass: "Field-Pass-123"

  Component {
    id: clientComponent
    MerginClient {
      createRequest: XhrShim.create
      store: MockSettings {}
    }
  }

  function makeClient() {
    const c = createTemporaryObject(clientComponent, tc);
    c.setServerUrl(serverUrl);
    return c;
  }

  function waitFor(spy, count, ms) {
    spy.wait(ms || 10000);
    if (count !== undefined) compare(spy.count, count);
  }

  SignalSpy { id: loginSpy; signalName: "loginFinished" }
  SignalSpy { id: serverSpy; signalName: "serverChecked" }
  SignalSpy { id: authSpy; signalName: "authRequired" }

  function init() {
    loginSpy.clear(); serverSpy.clear(); authSpy.clear();
  }

  function test_01_checkServer() {
    const c = makeClient();
    serverSpy.target = c;
    c.checkServer();
    waitFor(serverSpy, 1);
    verify(serverSpy.signalArguments[0][0], serverSpy.signalArguments[0][1]);
    verify(c.serverReachable);
    verify(/^\d{4}\.\d+\.\d+$/.test(c.serverVersion), c.serverVersion);
  }

  function test_02_checkServer_unreachable() {
    const c = makeClient();
    c.setServerUrl("http://127.0.0.1:9");
    serverSpy.target = c;
    c.checkServer();
    waitFor(serverSpy, 1);
    verify(!serverSpy.signalArguments[0][0]);
    verify(!c.serverReachable);
  }

  function test_03_login_wrong_password() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, "wrong-password", true);
    waitFor(loginSpy, 1);
    verify(!loginSpy.signalArguments[0][0]);
    compare(loginSpy.signalArguments[0][1], "Invalid username or password");
    verify(!c.loggedIn);
    compare(c.password, "");
    compare(c.store.value("qfield-mergin/password", "<none>"), "<none>", "a rejected password must never be stored");
  }

  function test_04_login_ok_not_remembered() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, false);
    waitFor(loginSpy, 1);
    verify(loginSpy.signalArguments[0][0], loginSpy.signalArguments[0][1]);
    verify(c.loggedIn);
    compare(c.username, user);
    compare(c.email, userEmail);
    verify(!c.tokenNeedsRenewal(), "fresh token should be valid: " + c.tokenExpiry);
    compare(c.store.value("qfield-mergin/password", "<none>"), "<none>");
    compare(c.store.value("qfield-mergin/authToken", ""), c.authToken);
  }

  function test_05_login_with_email() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(userEmail, pass, false);
    waitFor(loginSpy, 1);
    verify(loginSpy.signalArguments[0][0], loginSpy.signalArguments[0][1]);
    compare(c.username, user, "server returns the canonical username");
  }

  function test_06_authenticated_request() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, false);
    waitFor(loginSpy, 1);
    let result = null;
    c.authRequest("GET", "v1/user/profile", undefined, function (r) { result = { ok: true, r: r }; }, function (m, s) { result = { ok: false, m: m, s: s }; });
    tryVerify(function () { return result !== null; }, 10000);
    verify(result.ok, JSON.stringify(result));
    compare(result.r.username, user);
  }

  function test_07_expired_token_renewed_silently_with_remembered_password() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, true);
    waitFor(loginSpy, 1);
    compare(c.store.value("qfield-mergin/password", ""), pass);
    const oldToken = c.authToken;
    c.tokenExpiry = "2000-01-01T00:00:00Z";          // pretend the 12 h token lapsed
    authSpy.target = c;
    let result = null;
    c.authRequest("GET", "v1/user/profile", undefined, function (r) { result = { ok: true }; }, function (m, s) { result = { ok: false, m: m }; });
    tryVerify(function () { return result !== null; }, 10000);
    verify(result.ok, JSON.stringify(result));
    verify(c.authToken !== "" && !c.tokenNeedsRenewal());
    compare(authSpy.count, 0, "no user prompt when the password is remembered");
    verify(oldToken.length > 0);
  }

  function test_08_expired_token_without_password_asks_user() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, false);
    waitFor(loginSpy, 1);
    c.password = "";                                  // as after an app restart without "remember"
    c.tokenExpiry = "2000-01-01T00:00:00Z";
    authSpy.target = c;
    let result = null;
    c.authRequest("GET", "v1/user/profile", undefined, function () { result = { ok: true }; }, function (m, s) { result = { ok: false, m: m, s: s }; });
    tryVerify(function () { return result !== null; }, 10000);
    verify(!result.ok);
    compare(result.s, 401);
    compare(authSpy.count, 1);
    verify(!c.loggedIn);
    compare(c.loginName, user, "keeps the login name so the user only retypes the password");
  }

  function test_09_revoked_token_401_renews_once_and_retries() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, true);
    waitFor(loginSpy, 1);
    c.authToken = "invalid-token-from-server-perspective";   // valid expiry, but the server rejects it
    let result = null;
    c.authRequest("GET", "v1/user/profile", undefined, function (r) { result = { ok: true, r: r }; }, function (m, s) { result = { ok: false, m: m, s: s }; });
    tryVerify(function () { return result !== null; }, 10000);
    verify(result.ok, JSON.stringify(result));
    verify(c.authToken !== "invalid-token-from-server-perspective");
  }

  function test_10_concurrent_requests_share_one_renewal() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, true);
    waitFor(loginSpy, 1);
    c.tokenExpiry = "2000-01-01T00:00:00Z";
    let done = 0, failures = 0;
    for (let i = 0; i < 5; i++) {
      c.authRequest("GET", "v1/user/profile", undefined, function () { done++; }, function () { done++; failures++; });
    }
    compare(c._renewWaiters.length, 5, "five callers queued on one login request");
    tryVerify(function () { return done === 5; }, 15000);
    compare(failures, 0);
  }

  function test_11_persisted_session_restored() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, true);
    waitFor(loginSpy, 1);
    const c2 = createTemporaryObject(clientComponent, tc, { store: c.store });
    c2.loadSettings();
    compare(c2.serverUrl, serverUrl);
    compare(c2.authToken, c.authToken);
    compare(c2.username, user);
    verify(c2.rememberPassword);
    compare(c2.password, pass);
    let ok = null;
    c2.validateSession(function (v) { ok = v; });
    tryVerify(function () { return ok !== null; }, 10000);
    verify(ok);
  }

  function test_12_logout_and_server_change_clear_credentials() {
    const c = makeClient();
    loginSpy.target = c;
    c.login(user, pass, true);
    waitFor(loginSpy, 1);
    c.logout();
    verify(!c.loggedIn);
    compare(c.store.value("qfield-mergin/password", "<none>"), "<none>");
    compare(c.store.value("qfield-mergin/authToken", "x"), "");
    c.login(user, pass, true);
    waitFor(loginSpy, 2);
    c.setServerUrl("https://other.example.com");
    verify(!c.loggedIn);
    compare(c.password, "");
    compare(c.store.value("qfield-mergin/password", "<none>"), "<none>");
  }
}
