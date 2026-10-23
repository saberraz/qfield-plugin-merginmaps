"""Screencast part 2: the Mergin Maps web dashboard showing what QField pushed.

Logs in as the office user, opens the project history, the version pushed from QField (user agent "qfield|...")
and its feature-level changes. Runs a headed Chrome on $DISPLAY; record the screen separately.

Usage: python -I dashboard_demo.py <project, e.g. mergin/dummy-points> [dashboard url]
"""
import json, os, sys, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import Chrome

project = sys.argv[1]
base = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8080"
namespace, name = project.split("/")


def qfield_version():
    """Latest version pushed by the QField surveyor (the dashboard then shows its "qfield|..." user agent)."""
    req = urllib.request.Request(f"{base}/v1/auth/login", data=json.dumps({"login": "officeuser", "password": "Office-Pass-123"}).encode(),
                                 headers={"Content-Type": "application/json"})
    token = json.load(urllib.request.urlopen(req))["session"]["token"]
    req = urllib.request.Request(f"{base}/v1/project/versions/paginated/{project}?page=1&per_page=50&descending=true",
                                 headers={"Authorization": f"Bearer {token}"})
    versions = json.load(urllib.request.urlopen(req))["versions"]
    return [v["name"] for v in versions if v["author"] == "fielduser"][0]


def leaf(text):
    """JS for the first leaf element showing exactly `text`."""
    return f'[...document.querySelectorAll("a,button,span,div,td,p,h1,h2,h3")].filter(e => e.children.length === 0 && e.innerText && e.innerText.trim() === {json.dumps(text)})[0]'


version = qfield_version()
c = Chrome(width=1280, height=960, headless=False)
try:
    c.call("Page.enable")
    c.goto(base + "/", 1)
    c.wait_for('!!document.querySelector("input[name=login]")', 40)
    c.caption("Meanwhile, on the Mergin Maps dashboard")
    time.sleep(1.5)
    c.type_into('document.querySelector("input[name=login]")', "officeuser")
    c.type_into('document.querySelector("input[type=password]")', "Office-Pass-123")
    c.click('document.querySelector("#login-btn")', 1)
    c.wait_for('location.pathname === "/dashboard"', 20)
    time.sleep(1.5)
    c.caption(f"Open the project {name}")
    c.click(leaf("Projects"), 1.5)
    c.wait_for(f'!!{leaf(name)}', 20)
    c.click(leaf(name), 2)
    c.caption("Its history: every sync is a version")
    c.wait_for(f'!!{leaf("History")}', 20)
    c.click(leaf("History"), 2)
    c.wait_for(f'!!{leaf(version)}', 20)
    time.sleep(2.5)
    c.caption(f"{version} was pushed from QField by the surveyor")
    c.click(leaf(version), 2.5)
    c.wait_for('document.body.innerText.indexOf("qfield|") >= 0', 20)
    c.point('[...document.querySelectorAll("*")].filter(e => e.children.length === 0 && (e.innerText || "").indexOf("qfield|") === 0)[0]')
    c.caption("User agent: QField 4.3.6 with the Mergin Maps plugin")
    time.sleep(3.5)
    c.caption("Edited GeoPackage: one changeset, with per-layer counts")
    c.click(leaf("Show advanced"), 3)
    c.caption("Feature-level edit log of the changes made in QField")
    c.wait_for('document.body.innerText.indexOf("Change") >= 0', 20)
    time.sleep(1.5)
    c.point('document.querySelector("table tbody tr td") || document.querySelector("tbody")')   # the change-type icons, not the values
    time.sleep(5)
    c.caption("Same changesets as Mergin Maps mobile and QGIS: geodiff runs inside QField")
    time.sleep(4)
finally:
    c.close()
