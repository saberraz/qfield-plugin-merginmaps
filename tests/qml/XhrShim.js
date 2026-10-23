.pragma library

// Test double for QField's iface.createHttpRequest() (QfXmlHttpRequest) built on Qt's XMLHttpRequest:
// same callbacks (onload/onerror/ontimeout), rejects plain-object bodies like the real one mangles them,
// and exposes parsed JSON as `response`.
function create() {
  const xhr = new XMLHttpRequest();
  const req = { status: 0, response: undefined, responseText: "", timeout: 0, onload: null, onerror: null, ontimeout: null };
  let headers = [];
  req.open = function (method, url) { xhr.open(method, String(url)); };
  req.setRequestHeader = function (name, value) { headers.push([name, value]); };
  req.send = function (body) {
    const payload = body;
    if (body !== undefined && body !== null && typeof body === "object" && !(body instanceof ArrayBuffer)) {
      // Real QfXmlHttpRequest receives a JS object as a QJSValue and sends {"value": null}: fail loudly instead.
      throw new Error("QfXmlHttpRequest cannot send plain JS objects; JSON.stringify them and set Content-Type");
    }
    headers.forEach(function (h) { xhr.setRequestHeader(h[0], h[1]); });
    if (req.timeout > 0) xhr.timeout = req.timeout;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return;
      req.status = xhr.status;
      req.responseText = xhr.responseText;
      const type = (xhr.getResponseHeader("Content-Type") || "").toLowerCase();
      try { req.response = type.indexOf("json") >= 0 ? JSON.parse(xhr.responseText) : xhr.responseText; } catch (e) { req.response = xhr.responseText; }
      if (xhr.status === 0) { if (req.onerror) req.onerror(99, "network error"); }
      else if (req.onload) req.onload();
    };
    xhr.send(payload === undefined ? null : payload);
  };
  return req;
}
