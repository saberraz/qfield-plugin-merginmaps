"""Minimal Chrome DevTools Protocol driver for recording the Mergin Maps web dashboard in screencasts.

Starts Google Chrome (headed on $DISPLAY, or headless) with a throwaway profile and drives it with
Runtime.evaluate. A visible fake cursor and caption are injected into the page so recordings are easy to follow.
"""
import json, os, shutil, signal, socket, subprocess, tempfile, time, urllib.request

import websocket  # websocket-client


class Chrome:
    def __init__(self, width=1280, height=960, headless=False, port=None):
        if port is None:
            # a fresh free port each time, so a leftover browser can never be picked up by mistake
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                port = s.getsockname()[1]
        self.profile = tempfile.mkdtemp(prefix="cdp-chrome-")
        # no "Save password?" bubble over the recording
        os.makedirs(os.path.join(self.profile, "Default"))
        with open(os.path.join(self.profile, "Default", "Preferences"), "w") as fh:
            json.dump({"credentials_enable_service": False, "profile": {"password_manager_enabled": False}}, fh)
        args = ["google-chrome", f"--remote-debugging-port={port}", f"--user-data-dir={self.profile}",
                "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-sync",
                "--disable-features=Translate,PasswordManagerOnboarding", "--password-store=basic",
                f"--window-size={width},{height}", "--window-position=0,0", "--app=about:blank"]
        env = dict(os.environ)
        if headless:
            args.insert(1, "--headless=new")
        else:
            # draw on the X display being recorded ($DISPLAY), never on the user's Wayland desktop
            env.pop("WAYLAND_DISPLAY", None)
            args.insert(1, "--ozone-platform=x11")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=env)
        for _ in range(100):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
                page = [t for t in tabs if t.get("type") == "page"][0]
                break
            except Exception:
                time.sleep(0.2)
        self.ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
        self.msg_id = 0

    def call(self, method, **params):
        self.msg_id += 1
        self.ws.send(json.dumps({"id": self.msg_id, "method": method, "params": params}))
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == self.msg_id:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply.get("result", {})

    def js(self, expression):
        r = self.call("Runtime.evaluate", expression=expression, awaitPromise=True, returnByValue=True)
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"])
        return r.get("result", {}).get("value")

    def goto(self, url, settle=2.0):
        self.call("Page.navigate", url=url)
        time.sleep(settle)

    def wait_for(self, js_condition, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.js(js_condition):
                    return True
            except RuntimeError:
                pass
            time.sleep(0.25)
        raise TimeoutError(js_condition)

    def screenshot(self, path):
        data = self.call("Page.captureScreenshot", format="png")["data"]
        import base64
        open(path, "wb").write(base64.b64decode(data))

    # ---- screencast helpers: fake cursor + caption overlay ----
    OVERLAY = r"""
    (function () {
      if (window.__demo) return;
      const cur = document.createElement('div');
      cur.style.cssText = 'position:fixed;z-index:2147483647;width:36px;height:36px;border-radius:18px;' +
        'background:rgba(115,209,156,0.55);border:3px solid #004C45;left:-60px;top:-60px;pointer-events:none;' +
        'transition:left .45s ease-in-out, top .45s ease-in-out, transform .12s;';
      const cap = document.createElement('div');
      cap.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:24px;transform:translateX(-50%);' +
        'max-width:80%;padding:12px 20px;border-radius:12px;background:rgba(32,48,56,0.92);color:#fff;' +
        'font:600 20px sans-serif;text-align:center;display:none;pointer-events:none;';
      document.body.appendChild(cur); document.body.appendChild(cap);
      window.__demo = { cur: cur, cap: cap };
    })();"""

    def overlay(self):
        self.js(self.OVERLAY)

    def caption(self, text):
        self.overlay()
        self.js(f"window.__demo.cap.textContent = {json.dumps(text)}; window.__demo.cap.style.display = {json.dumps('block' if text else 'none')};")

    def point(self, selector_js):
        """Move the fake cursor to the element returned by `selector_js` (a JS expression)."""
        self.overlay()
        self.js(f"""(function () {{ const el = {selector_js}; el.scrollIntoView({{block: 'center'}});
            const r = el.getBoundingClientRect(); window.__demo.cur.style.left = (r.left + r.width / 2 - 18) + 'px';
            window.__demo.cur.style.top = (r.top + r.height / 2 - 18) + 'px'; }})()""")
        time.sleep(0.7)

    def click(self, selector_js, pause=0.4):
        self.point(selector_js)
        self.js(f"window.__demo.cur.style.transform = 'scale(0.7)';")
        time.sleep(0.15)
        self.js(f"window.__demo.cur.style.transform = 'scale(1)'; ({selector_js}).click();")
        time.sleep(pause)

    def type_into(self, selector_js, text, delay=0.06):
        """Types like a user so Vue's v-model sees input events."""
        self.point(selector_js)
        self.js(f"(function () {{ const el = {selector_js}; el.focus(); el.value = ''; el.dispatchEvent(new Event('input', {{bubbles: true}})); }})()")
        for i in range(1, len(text) + 1):
            self.js(f"(function () {{ const el = {selector_js}; el.value = {json.dumps(text[:i])}; el.dispatchEvent(new Event('input', {{bubbles: true}})); }})()")
            time.sleep(delay)

    def close(self):
        try:
            self.ws.close()
        finally:
            # Chrome spawns helper processes: stop the whole process group
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            shutil.rmtree(self.profile, ignore_errors=True)
