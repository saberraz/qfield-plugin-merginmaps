"""Page-only screenshots of the Mergin Maps dashboard showing the version QField pushed (headless Chrome, 2x)."""
import json, os, sys, time, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "web"))
from cdp import Chrome

base, project, out = "http://127.0.0.1:8080", "mergin/bee-farming", sys.argv[1]
ns, name = project.split("/")
req = urllib.request.Request(f"{base}/v1/auth/login", data=json.dumps({"login": "officeuser", "password": "Office-Pass-123"}).encode(),
                             headers={"Content-Type": "application/json"})
token = json.load(urllib.request.urlopen(req))["session"]["token"]
req = urllib.request.Request(f"{base}/v1/project/versions/paginated/{project}?page=1&per_page=50&descending=true", headers={"Authorization": f"Bearer {token}"})
versions = json.load(urllib.request.urlopen(req))["versions"]
version = [v["name"] for v in versions if v["author"] == "fielduser"][-1]   # first QField push: an edit + a new feature
print("QField version", version)

def leaf(text):
    return f'[...document.querySelectorAll("a,button,span,div,td,p,h1,h2,h3")].filter(e => e.children.length === 0 && e.innerText && e.innerText.trim() === {json.dumps(text)})[0]'

def click(c, js):
    c.js(f"({js}).click()")
    time.sleep(1.5)

c = Chrome(width=1280, height=820, headless=True)
try:
    c.call("Page.enable")
    c.call("Emulation.setDeviceMetricsOverride", width=1280, height=820, deviceScaleFactor=2, mobile=False)
    c.goto(base + "/", 2)
    c.wait_for('!!document.querySelector("input[name=login]")', 40)
    c.js('(() => { const set = (el, v) => { const p = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set; p.call(el, v); el.dispatchEvent(new Event("input", {bubbles: true})); }; set(document.querySelector("input[name=login]"), "officeuser"); set(document.querySelector("input[type=password]"), "Office-Pass-123"); })()')
    click(c, 'document.querySelector("#login-btn")')
    c.wait_for('location.pathname === "/dashboard"', 20)
    c.goto(f"{base}/projects/{ns}/{name}/history", 3)
    c.wait_for(f'!!{leaf(version)}', 20)
    c.screenshot(os.path.join(out, "dash_history.png"))
    click(c, leaf(version))
    c.wait_for('document.body.innerText.indexOf("qfield|") >= 0', 20)
    time.sleep(1)
    c.screenshot(os.path.join(out, "dash_version.png"))
    click(c, leaf("Show advanced"))
    c.wait_for('document.body.innerText.indexOf("Change") >= 0', 20)
    time.sleep(2)
    c.screenshot(os.path.join(out, "dash_changes.png"))
finally:
    c.close()
