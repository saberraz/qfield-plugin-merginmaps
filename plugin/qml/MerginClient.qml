import QtQuick

import "../js/merginutils.js" as MerginUtils

// Session state and REST access for one Mergin Maps server.
//
// Authentication mirrors Mergin Maps mobile: POST /v1/auth/login returns a bearer token (12 h by default). When the
// token is missing or about to expire it is renewed by logging in again, either silently with a remembered
// password or by asking the user (authRequired). A 401 on an authenticated call triggers one renewal and retry.
QtObject {
  id: client

  readonly property string settingsPrefix: "qfield-mergin/"

  // Injectable for tests. In QField these are iface.createHttpRequest() (proxy aware) and QField's settings.
  property var createRequest: function () { return iface.createHttpRequest(); }
  property var createBinaryRequest: function () { return new XMLHttpRequest(); }
  property var store: typeof settings !== "undefined" ? settings : null

  property string serverUrl: MerginUtils.DEFAULT_SERVER_URL
  property string loginName: ""          // what the user typed: username or email
  property string username: ""           // canonical username returned by the server
  property string email: ""
  property string authToken: ""
  property string tokenExpiry: ""        // ISO 8601, as returned by the server
  property bool rememberPassword: false
  property string password: ""           // kept in memory; persisted only when rememberPassword is true

  // Filled by checkServer() from /config.
  property string serverVersion: ""
  property bool serverReachable: false
  property bool serverSsoEnabled: false
  property string serverType: ""          // "saas", "ee" or "ce" from /config; "" until checked
  property bool serverSelfRegistration: false
  readonly property string signUpUrl: MerginUtils.signUpUrl(serverUrl, serverType, serverSelfRegistration)

  property bool busy: false
  readonly property bool loggedIn: authToken !== ""

  signal serverChecked(bool ok, string message)
  signal loginFinished(bool ok, string message)
  // Emitted when an authenticated call cannot proceed without the user entering their password again.
  signal authRequired(string message)

  property var _renewWaiters: []

  // Qt's XMLHttpRequest (used for binary transfers) has no timeout: a watchdog aborts transfers that make no progress,
  // which then fail through the normal error path (sync restores local files and reports the error).
  property int transferTimeoutMs: 120000
  property var _transfers: []
  property Timer _watchdog: Timer {
    interval: 2000
    repeat: true
    running: client._transfers.length > 0
    onTriggered: {
      const now = Date.now();
      client._transfers.forEach(function (t) {
        if (!t.done && now - t.lastActivity > client.transferTimeoutMs) {
          t.timedOut = true;
          client.log("Transfer timed out: " + t.url);
          t.xhr.abort();
        }
      });
      client._transfers = client._transfers.filter(function (t) { return !t.done && !t.timedOut; });
    }
  }

  function _track(xhr, url) {
    const t = { xhr: xhr, url: url, lastActivity: Date.now(), done: false, timedOut: false };
    _transfers = _transfers.concat([t]);
    return t;
  }

  function log(message) {
    if (typeof iface !== "undefined") {
      iface.logMessage(MerginUtils.LOG_PREFIX + message);
    } else {
      console.log(MerginUtils.LOG_PREFIX + message);
    }
  }

  function loadSettings() {
    if (!store) {
      return;
    }
    serverUrl = MerginUtils.normaliseServerUrl(store.value(settingsPrefix + "serverUrl", MerginUtils.DEFAULT_SERVER_URL));
    loginName = store.value(settingsPrefix + "loginName", "");
    username = store.value(settingsPrefix + "username", "");
    email = store.value(settingsPrefix + "email", "");
    authToken = store.value(settingsPrefix + "authToken", "");
    tokenExpiry = store.value(settingsPrefix + "tokenExpiry", "");
    rememberPassword = store.valueBool(settingsPrefix + "rememberPassword", false);
    password = rememberPassword ? store.value(settingsPrefix + "password", "") : "";
  }

  function saveSettings() {
    if (!store) {
      return;
    }
    store.setValue(settingsPrefix + "serverUrl", serverUrl);
    store.setValue(settingsPrefix + "loginName", loginName);
    store.setValue(settingsPrefix + "username", username);
    store.setValue(settingsPrefix + "email", email);
    store.setValue(settingsPrefix + "authToken", authToken);
    store.setValue(settingsPrefix + "tokenExpiry", tokenExpiry);
    store.setValue(settingsPrefix + "rememberPassword", rememberPassword);
    if (rememberPassword && password !== "") {
      store.setValue(settingsPrefix + "password", password);
    } else {
      store.remove(settingsPrefix + "password");
    }
  }

  function setServerUrl(url) {
    const normalised = MerginUtils.normaliseServerUrl(url);
    if (normalised !== serverUrl) {
      // Credentials belong to the server that issued them.
      serverUrl = normalised;
      clearSession(true);
      serverReachable = false;
      serverVersion = "";
      serverSsoEnabled = false;
      serverType = "";
      serverSelfRegistration = false;
      saveSettings();
    }
  }

  function clearSession(forgetUser) {
    authToken = "";
    tokenExpiry = "";
    if (forgetUser) {
      username = "";
      email = "";
      password = "";
    }
  }

  function tokenNeedsRenewal() {
    return MerginUtils.tokenNeedsRenewal(authToken, tokenExpiry, Date.now());
  }

  // Low-level request. `path` is relative to the server root, e.g. "v1/project". A JS object body is sent as JSON.
  // onSuccess(response, request) is called for 2xx, onFailure(message, status) otherwise (status 0: network error).
  function rawRequest(method, path, body, withToken, onSuccess, onFailure) {
    const request = createRequest();
    const url = MerginUtils.joinUrl(serverUrl, path);
    request.timeout = 30000;
    request.onload = function () {
      if (request.status >= 200 && request.status < 300) {
        onSuccess(request.response, request);
      } else {
        const message = MerginUtils.errorMessage(request.response, qsTr("Server returned HTTP %1").arg(request.status));
        log(method + " " + url + " failed: " + request.status + " " + message);
        onFailure(message, request.status);
      }
    };
    request.onerror = function (code, message) {
      log(method + " " + url + " network error " + code + ": " + message);
      onFailure(message || qsTr("Network error"), 0);
    };
    request.ontimeout = function () {
      log(method + " " + url + " timed out");
      onFailure(qsTr("The request timed out"), 0);
    };
    request.open(method, url);
    if (withToken && authToken !== "") {
      request.setRequestHeader("Authorization", "Bearer " + authToken);
    }
    if (body !== undefined && body !== null && typeof body === "object" && !(body instanceof ArrayBuffer)) {
      // A JS object reaches QfXmlHttpRequest as a QJSValue, which it encodes as {"value": null}. Send JSON text.
      request.setRequestHeader("Content-Type", "application/json");
      request.send(JSON.stringify(body));
    } else {
      request.send(body === undefined ? undefined : body);
    }
  }

  function checkServer() {
    busy = true;
    rawRequest("GET", "config", undefined, false, function (response) {
      busy = false;
      const info = MerginUtils.serverInfoFromConfig(response);
      serverReachable = info !== null;
      serverVersion = info ? info.version : "";
      serverSsoEnabled = info ? info.ssoEnabled : false;
      serverType = info ? info.serverType : "";
      serverSelfRegistration = info ? info.userSelfRegistration : false;
      if (!info) {
        serverChecked(false, qsTr("%1 does not look like a Mergin Maps server").arg(serverUrl));
      } else {
        serverChecked(true, qsTr("Connected to Mergin Maps %1").arg(serverVersion));
      }
    }, function (message) {
      busy = false;
      serverReachable = false;
      serverVersion = "";
      serverChecked(false, qsTr("Cannot reach server: %1").arg(message));
    });
  }

  // Interactive login. `remember` stores the password (unencrypted, in QField's settings) for silent token renewal.
  function login(name, pass, remember) {
    busy = true;
    loginName = name.trim();
    password = pass;
    rememberPassword = remember;
    _requestToken(function (ok, message) {
      busy = false;
      if (!ok) {
        // only ever persist a password the server has accepted
        password = "";
      }
      saveSettings();
      loginFinished(ok, message);
    });
  }

  function logout() {
    log("Logged out " + username);
    clearSession(true);
    rememberPassword = false;
    saveSettings();
  }

  // Calls back with (true) once a usable token exists, renewing it if needed, or (false, message) if the user
  // has to log in again. Concurrent callers share one renewal.
  function ensureAuth(callback) {
    if (!tokenNeedsRenewal()) {
      callback(true, "");
      return;
    }
    if (loginName === "" || password === "") {
      clearSession(false);
      saveSettings();
      const message = loginName === "" ? qsTr("Please log in to Mergin Maps") : qsTr("Your Mergin Maps session expired, please log in again");
      authRequired(message);
      callback(false, message);
      return;
    }
    _renewWaiters.push(callback);
    if (_renewWaiters.length > 1) {
      return;
    }
    log("Renewing token for " + loginName);
    _requestToken(function (ok, message) {
      saveSettings();
      if (!ok) {
        authRequired(message);
      }
      const waiters = _renewWaiters;
      _renewWaiters = [];
      waiters.forEach(function (w) { w(ok, message); });
    });
  }

  function _requestToken(done) {
    rawRequest("POST", "v1/auth/login", { login: loginName, password: password }, false, function (response) {
      const session = MerginUtils.sessionFromLoginResponse(response);
      if (!session) {
        clearSession(false);
        done(false, qsTr("The server did not return a session token"));
        return;
      }
      authToken = session.token;
      tokenExpiry = session.expire;
      username = session.username || loginName;
      email = session.email;
      log("Logged in as " + username + ", token valid until " + tokenExpiry);
      done(true, qsTr("Logged in as %1").arg(username));
    }, function (message, status) {
      clearSession(false);
      if (status === 401 || status === 400) {
        // wrong credentials: never keep a password that no longer works
        password = "";
      }
      done(false, status === 0 ? qsTr("Cannot reach server: %1").arg(message) : message);
    });
  }

  // Authenticated request with automatic renewal. A 401 (e.g. token revoked server-side) renews once and retries.
  function authRequest(method, path, body, onSuccess, onFailure) {
    ensureAuth(function (ok, message) {
      if (!ok) {
        onFailure(message, 401);
        return;
      }
      rawRequest(method, path, body, true, onSuccess, function (failMessage, status) {
        if (status !== 401) {
          onFailure(failMessage, status);
          return;
        }
        log(method + " " + path + " returned 401, renewing token once");
        authToken = "";
        ensureAuth(function (renewed, renewMessage) {
          if (!renewed) {
            onFailure(renewMessage, 401);
            return;
          }
          rawRequest(method, path, body, true, onSuccess, onFailure);
        });
      });
    });
  }

  // Authenticated binary GET of bytes [from, to] (inclusive). QfXmlHttpRequest decodes bodies as UTF-8, so binary
  // downloads use Qt's own XMLHttpRequest with responseType "arraybuffer". onSuccess(ArrayBuffer).
  function authDownloadRange(path, query, from, to, onSuccess, onFailure) {
    ensureAuth(function (ok, message) {
      if (!ok) {
        onFailure(message, 401);
        return;
      }
      const url = MerginUtils.joinUrl(serverUrl, path) + (query ? "?" + query : "");
      const xhr = createBinaryRequest();
      xhr.open("GET", url);
      xhr.responseType = "arraybuffer";
      xhr.setRequestHeader("Authorization", "Bearer " + authToken);
      xhr.setRequestHeader("Range", "bytes=" + from + "-" + to);
      const transfer = _track(xhr, url);
      xhr.onreadystatechange = function () {
        transfer.lastActivity = Date.now();
        if (xhr.readyState !== XMLHttpRequest.DONE) {
          return;
        }
        transfer.done = true;
        if (transfer.timedOut) {
          onFailure(qsTr("The connection timed out"), 0);
          return;
        }
        const expected = to - from + 1;
        const got = xhr.response ? xhr.response.byteLength : 0;
        // 200 is fine too when the whole file fits in the requested range; the byte count is what matters.
        if ((xhr.status === 206 || xhr.status === 200) && got === expected) {
          onSuccess(got ? xhr.response : new ArrayBuffer(0));
        } else if (xhr.status === 401) {
          authToken = "";
          onFailure(qsTr("Your Mergin Maps session expired, please log in again"), 401);
        } else {
          const message = xhr.status === 0 ? qsTr("Network error") : qsTr("Download failed (HTTP %1, %2 of %3 bytes)").arg(xhr.status).arg(got).arg(expected);
          log("GET " + url + " bytes " + from + "-" + to + ": " + message);
          onFailure(message, xhr.status);
        }
      };
      xhr.send();
    });
  }

  // Authenticated binary POST (push chunks). Uses Qt's XMLHttpRequest: QfXmlHttpRequest would receive an
  // ArrayBuffer as a QJSValue, like plain objects. onSuccess(response text).
  function authUpload(path, buffer, onSuccess, onFailure) {
    ensureAuth(function (ok, message) {
      if (!ok) {
        onFailure(message, 401);
        return;
      }
      const url = MerginUtils.joinUrl(serverUrl, path);
      const xhr = createBinaryRequest();
      xhr.open("POST", url);
      xhr.setRequestHeader("Authorization", "Bearer " + authToken);
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      const transfer = _track(xhr, url);
      xhr.onreadystatechange = function () {
        transfer.lastActivity = Date.now();
        if (xhr.readyState !== XMLHttpRequest.DONE) {
          return;
        }
        transfer.done = true;
        if (transfer.timedOut) {
          onFailure(qsTr("The connection timed out"), 0);
          return;
        }
        if (xhr.status >= 200 && xhr.status < 300) {
          onSuccess(xhr.responseText);
        } else {
          let detail = xhr.responseText;
          try { detail = MerginUtils.errorMessage(JSON.parse(xhr.responseText), xhr.responseText); } catch (e) {}
          const message = xhr.status === 0 ? qsTr("Network error") : qsTr("Upload failed (HTTP %1): %2").arg(xhr.status).arg(detail);
          log("POST " + url + ": " + message);
          onFailure(message, xhr.status);
        }
      };
      xhr.send(buffer);
    });
  }

  // Confirms a stored session still works (e.g. at startup) and refreshes the profile.
  function validateSession(callback) {
    authRequest("GET", "v1/user/profile", undefined, function (response) {
      if (response && response.username) {
        username = String(response.username);
        email = response.email ? String(response.email) : email;
        saveSettings();
      }
      callback(true, "");
    }, function (message) {
      callback(false, message);
    });
  }

  Component.onCompleted: loadSettings()
}
