.pragma library

// Pure helpers shared by the plugin. No access to iface/settings here.

var DEFAULT_SERVER_URL = "https://app.merginmaps.com";
var LOG_PREFIX = "[Mergin] ";


// Renew the token this long before the server-side expiry, so a request never starts with a token about to lapse.
var TOKEN_RENEW_MARGIN_MS = 5 * 60 * 1000;

// Trims whitespace and trailing slashes, and adds https:// when no scheme is given.
function normaliseServerUrl(url) {
  var value = (url || "").trim();
  if (value === "") {
    return DEFAULT_SERVER_URL;
  }
  if (!/^[a-z][a-z0-9+\-.]*:\/\//i.test(value)) {
    value = "https://" + value;
  }
  return value.replace(/\/+$/, "");
}

function joinUrl(serverUrl, path) {
  return normaliseServerUrl(serverUrl) + "/" + String(path).replace(/^\/+/, "");
}

// Extracts a human readable message from a Mergin API error response.
function errorMessage(response, fallback) {
  if (response && typeof response === "object" && response.detail) {
    return String(response.detail);
  }
  if (typeof response === "string" && response.length > 0 && response.length < 300) {
    return response;
  }
  return fallback;
}

// Parses the server's ISO 8601 timestamps (e.g. "2026-10-22T23:41:14.335865+00:00") into epoch milliseconds.
// Python emits microseconds, which not every JS engine's Date.parse accepts, so the fraction is cut to milliseconds.
// Returns NaN when the value cannot be parsed.
function parseIsoDate(value) {
  if (typeof value !== "string") {
    return NaN;
  }
  var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$/.exec(value.trim());
  if (!m) {
    return NaN;
  }
  var ms = m[7] ? Number((m[7] + "00").substring(0, 3)) : 0;
  var utc = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]), ms);
  var zone = m[8];
  if (zone && zone !== "Z") {
    var sign = zone[0] === "-" ? -1 : 1;
    var digits = zone.substring(1).replace(":", "");
    var offsetMinutes = Number(digits.substring(0, 2)) * 60 + Number(digits.substring(2, 4));
    utc -= sign * offsetMinutes * 60 * 1000;
  }
  return utc;
}

// True when a token with this expiry must be renewed before use (missing, unparsable, expired or within the margin).
function tokenNeedsRenewal(token, expiryIso, nowMs) {
  if (!token) {
    return true;
  }
  var expiry = parseIsoDate(expiryIso);
  return isNaN(expiry) || expiry - nowMs <= TOKEN_RENEW_MARGIN_MS;
}

// Extracts {token, expire, username, email} from a /v1/auth/login response.
// The server returns the session nested under "session"; the OpenAPI spec documents it at the top level, so accept both.
// Returns null when no token is present.
function sessionFromLoginResponse(response) {
  if (!response || typeof response !== "object") {
    return null;
  }
  var session = response.session && typeof response.session === "object" ? response.session : response;
  if (!session.token) {
    return null;
  }
  return {
    token: String(session.token),
    expire: session.expire ? String(session.expire) : "",
    username: response.username ? String(response.username) : "",
    email: response.email ? String(response.email) : ""
  };
}

// Parses "/config" into {version, major, minor, ssoEnabled, serverType}, or null if it is not a Mergin server.
function serverInfoFromConfig(config) {
  if (!config || typeof config !== "object" || config.major === undefined || config.minor === undefined) {
    return null;
  }
  return {
    version: config.version ? String(config.version) : config.major + "." + config.minor + "." + (config.fix || 0),
    major: Number(config.major),
    minor: Number(config.minor),
    ssoEnabled: config.sso_enabled === true,
    serverType: config.server_type ? String(config.server_type) : "",
    userSelfRegistration: config.user_self_registration === true
  };
}

// Where "Sign up" leads, as in Mergin Maps mobile: only hosted (saas) and Enterprise (ee) servers that allow
// self-registration; Community Edition accounts are created by the server admin. Mobile signs SaaS users up in the
// app; the plugin opens the dashboard's registration page instead. Mobile opens the server root for EE.
// serverType "" (config not loaded yet) falls back to the default hosted server.
function signUpUrl(serverUrl, serverType, selfRegistration) {
  var url = normaliseServerUrl(serverUrl);
  if (serverType === "") {
    return url === DEFAULT_SERVER_URL ? joinUrl(url, "register") : "";
  }
  if (!selfRegistration) return "";
  if (serverType === "saas") return joinUrl(url, "register");
  if (serverType === "ee") return url;
  return "";
}

// Mergin Maps mobile's "Forgot password?" target
function resetPasswordUrl(serverUrl) {
  return joinUrl(serverUrl, "login/reset");
}

// ---- projects ----

var DOWNLOAD_CHUNK_SIZE = 10 * 1024 * 1024;   // same as Mergin mobile / server

// Byte ranges [from, to] (inclusive) covering a file of `size` bytes in chunks of `chunkSize`.
function chunkRanges(size, chunkSize) {
  var ranges = [];
  var step = chunkSize || DOWNLOAD_CHUNK_SIZE;
  for (var from = 0; from < size; from += step) {
    ranges.push([from, Math.min(from + step, size) - 1]);
  }
  return ranges;
}

// Lower-case hex of an ArrayBuffer (e.g. the QByteArray returned by QfFileUtils.fileChecksum).
function hexFromBuffer(buffer) {
  if (!buffer) {
    return "";
  }
  var bytes = new Uint8Array(buffer);
  var out = "";
  for (var i = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
  }
  return out;
}

// A server-provided project file path is only accepted if it stays inside the project folder.
function isSafeRelativePath(path) {
  if (typeof path !== "string" || path === "" || path.length > 1024) {
    return false;
  }
  if (path[0] === "/" || path[0] === "\\" || /^[a-zA-Z]:/.test(path) || path.indexOf("\0") >= 0) {
    return false;
  }
  var parts = path.split(/[\/\\]/);
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === ".." || parts[i] === "") {
      return false;
    }
  }
  return true;
}

function isGeoPackage(path) {
  return /\.gpkg$/i.test(path);
}

// The QGIS project file of a Mergin project: a .qgz/.qgs at the project root (Mergin allows exactly one).
function findProjectFile(files) {
  var candidates = files.map(function (f) { return f.path; })
                        .filter(function (p) { return /\.(qgz|qgs)$/i.test(p) && p.indexOf("/") < 0; })
                        .sort();
  return candidates.length ? candidates[0] : "";
}

// Query string for /v1/project/raw/<ns>/<name>; file paths may contain spaces, '&', '+' and Unicode.
function rawFileQuery(path, version) {
  return "file=" + encodeURIComponent(path) + "&version=" + encodeURIComponent(version);
}

function projectFullName(namespace, name) {
  return namespace + "/" + name;
}

function directoryOf(path) {
  var i = String(path).lastIndexOf("/");
  return i > 0 ? path.substring(0, i) : "";
}

function fileNameOf(path) {
  return String(path).substring(String(path).lastIndexOf("/") + 1);
}

// UTF-8 bytes of a string as an ArrayBuffer (Qt's JS engine has no TextEncoder).
function utf8Encode(text) {
  var bytes = [];
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
      var d = text.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        i++;
      }
    }
    if (c < 0x80) {
      bytes.push(c);
    } else if (c < 0x800) {
      bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    } else if (c < 0x10000) {
      bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    } else {
      bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  return new Uint8Array(bytes).buffer;
}

// Mergin project and workspace names become folder names: accept only a single, non-special path segment.
function isSafeName(name) {
  return typeof name === "string" && name !== "" && name !== "." && name !== ".." && isSafeRelativePath(name) && name.indexOf("/") < 0 && name.indexOf("\\") < 0;
}

// String from UTF-8 bytes (ArrayBuffer), e.g. QfFileUtils.readFileContent() of a JSON file.
function utf8Decode(buffer) {
  var bytes = new Uint8Array(buffer || new ArrayBuffer(0));
  var out = [];
  for (var i = 0; i < bytes.length;) {
    var b = bytes[i++];
    var c;
    if (b < 0x80) {
      c = b;
    } else if (b >= 0xf0) {
      c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
    } else if (b >= 0xe0) {
      c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
    } else {
      c = ((b & 31) << 6) | (bytes[i++] & 63);
    }
    if (c >= 0x10000) {
      c -= 0x10000;
      out.push(String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023)));
    } else {
      out.push(String.fromCharCode(c));
    }
  }
  return out.join("");
}

// "Updated just now / 5 minutes ago / 2 hours ago / 3 days ago / 2 weeks ago / on 2026-01-02" (Mergin mobile wording).
function relativeTime(iso, nowMs) {
  var t = parseIsoDate(iso);
  if (isNaN(t)) {
    return "";
  }
  var s = Math.max(0, Math.round((nowMs - t) / 1000));
  var plural = function (n, unit) { return n + " " + unit + (n === 1 ? "" : "s") + " ago"; };
  if (s < 60) return "just now";
  if (s < 3600) return plural(Math.floor(s / 60), "minute");
  if (s < 86400) return plural(Math.floor(s / 3600), "hour");
  if (s < 7 * 86400) return plural(Math.floor(s / 86400), "day");
  if (s < 31 * 86400) return plural(Math.floor(s / (7 * 86400)), "week");
  return "on " + iso.substring(0, 10);
}

// ---- workspaces ----

// Which workspace to show, like Mergin Maps mobile: the only one; else the last used one if still available; else the
// server's preferred workspace; else the first. workspaces: [{id, name}]. Returns an id or -1.
function chooseWorkspace(workspaces, lastUsedId, preferredId) {
  if (!workspaces || workspaces.length === 0) {
    return -1;
  }
  if (workspaces.length === 1) {
    return workspaces[0].id;
  }
  var has = function (id) { return workspaces.some(function (w) { return w.id === id; }); };
  if (has(lastUsedId)) {
    return lastUsedId;
  }
  if (has(preferredId)) {
    return preferredId;
  }
  return workspaces[0].id;
}

// Initials for the account avatar (mobile: CoreUtils::nameAbbr): first letters of a full name, else of the username.
function initials(name, username) {
  var source = (name || "").trim();
  if (source) {
    var parts = source.split(/\s+/);
    return ((parts[0][0] || "") + (parts.length > 1 ? parts[parts.length - 1][0] : "")).toUpperCase();
  }
  return (username || "?").substring(0, 2).toUpperCase();
}

// Case-insensitive match of a search text against a project's name and "<namespace>/<name>".
function matchesSearch(text, namespace, name) {
  var t = (text || "").trim().toLowerCase();
  if (!t) {
    return true;
  }
  return name.toLowerCase().indexOf(t) >= 0 || (namespace + "/" + name).toLowerCase().indexOf(t) >= 0;
}

// JSON arrays parsed by QField's QfXmlHttpRequest arrive as Qt sequence objects, for which Array.isArray() is false.
function toArray(value) {
  if (!value || typeof value !== "object") return [];
  if (Array.isArray(value)) return value;
  return typeof value.length === "number" ? Array.prototype.slice.call(value) : [];
}
