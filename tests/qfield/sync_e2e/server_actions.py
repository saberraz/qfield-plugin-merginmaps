"""Server-side half of the sync end-to-end test: an office colleague (officeuser) editing the same project with the
official Mergin Maps Python client while the surveyor works in QField, plus the final checks.

Usage (called by run_e2e.sh): python -I server_actions.py <action> <work dir>
  office_edit      update tree 3, add a tree, add notes/office.txt, push
  office_conflict  set height of tree 5 to 99 (the surveyor edits the same attribute in QField), push
  stop_server / start_server   take the Mergin server down / bring it back (sync must fail safely, then recover)
  office_remove    delete notes/office.txt on the server (QField cannot delete it locally; it must not come back)
  check            verify server and QField copies (exit 1 on failure)
"""
import glob, hashlib, json, os, shutil, sqlite3, sys, tempfile

from mergin import MerginClient
from osgeo import gdal, ogr

gdal.UseExceptions()
PROJECT = "mergin/dummy-points"
action, work = sys.argv[1], sys.argv[2]
office = os.path.join(work, "office")
# logged in lazily: start_server runs while the server is down
mc = None if action in ("stop_server", "start_server") else MerginClient("http://127.0.0.1:5000", login="officeuser", password="Office-Pass-123")


def office_copy():
    if os.path.exists(office):
        mc.pull_project(office)
    else:
        mc.download_project(PROJECT, office)
    return office


def edit(where, values):
    ds = ogr.Open(os.path.join(office, "trees.gpkg"), 1)
    lyr = ds.GetLayer("trees")
    lyr.SetAttributeFilter(where)
    for f in lyr:
        for k, v in values.items():
            f.SetField(k, v)
        lyr.SetFeature(f)
    ds = None


def trees(path):
    con = sqlite3.connect(path)
    rows = {r[0]: (r[1], r[2]) for r in con.execute("SELECT fid, species, height_m FROM trees")}
    con.close()
    return rows


if action == "office_edit":
    office_copy()
    edit("fid = 3", {"species": "Office Oak"})
    ds = ogr.Open(os.path.join(office, "trees.gpkg"), 1); lyr = ds.GetLayer("trees")
    f = ogr.Feature(lyr.GetLayerDefn()); f.SetField("species", "Office tree"); f.SetField("height_m", 7.5); f.SetField("surveyor", "office")
    f.SetGeometry(ogr.CreateGeometryFromWkt("POINT (-0.1400 50.8230)")); lyr.CreateFeature(f); ds = None
    os.makedirs(os.path.join(office, "notes"), exist_ok=True)
    open(os.path.join(office, "notes", "office.txt"), "w").write("Checked from the office\n")
    mc.push_project(office)
    print("office_edit pushed", mc.project_info(PROJECT)["version"])
elif action == "office_conflict":
    office_copy()
    edit("fid = 5", {"height_m": 99.0})
    mc.push_project(office)
    print("office_conflict pushed", mc.project_info(PROJECT)["version"])
elif action == "office_remove":
    office_copy()
    os.remove(os.path.join(office, "notes", "office.txt"))
    mc.push_project(office)
    print("office_remove pushed", mc.project_info(PROJECT)["version"])
elif action == "stop_server":
    import subprocess
    subprocess.run(["podman", "stop", "-t", "2", "mm-server"], check=True, capture_output=True)
    print("server stopped")
elif action == "start_server":
    import subprocess, time, urllib.request
    subprocess.run(["podman", "start", "mm-server"], check=True, capture_output=True)
    # the dashboard's nginx proxy (if running) caches the server's old container IP
    subprocess.run(["podman", "restart", "mm-proxy"], capture_output=True)
    for _ in range(60):
        try:
            urllib.request.urlopen("http://127.0.0.1:5000/config", timeout=2); break
        except Exception:
            time.sleep(1)
    print("server started")
elif action == "check":
    failures = []
    def expect(cond, what):
        print(("PASS " if cond else "FAIL ") + what)
        if not cond:
            failures.append(what)
    info = mc.project_info(PROJECT)
    latest = tempfile.mkdtemp()
    shutil.rmtree(latest); mc.download_project(PROJECT, latest)
    server = trees(os.path.join(latest, "trees.gpkg"))
    files = sorted(f["path"] for f in info["files"])
    print("server version", info["version"], "files", files)
    print("server trees", json.dumps(server, sort_keys=True))
    expect(server.get(1, (None,))[0] == "Field Ash", "QField attribute edit on tree 1 reached the server")
    expect(2 not in server, "QField deletion of tree 2 reached the server")
    expect(any(v[0] == "Field tree" for v in server.values()), "QField new tree reached the server")
    expect(server.get(3, (None,))[0] == "Office Oak", "office edit on tree 3 kept")
    expect(any(v[0] == "Office tree" for v in server.values()), "office new tree kept")
    expect(server.get(4, (None,))[0] == "Field Beech", "QField edit made while the office pushed (tree 4) merged")
    expect(server.get(5, (None, None))[1] in (11.0, 99.0), f"tree 5 has one of the conflicting heights: {server.get(5)}")
    expect(server.get(6, (None,))[0] == "Offline Yew", "edit kept through a failed sync (server down) and pushed later")
    expect("DCIM/field_photo.jpg" in files, "photo taken in QField uploaded")
    expect("notes/office.txt" not in files, "file removed in the office was not pushed back by QField")
    expect(not any(f.startswith("mm_") and f.endswith(".qgz") for f in files), "QField folder stub not uploaded")
    expect(any("(edit conflict, fielduser v" in f for f in files), "edit conflict file uploaded like the other Mergin clients")
    expect(not any(f.endswith(".qgs.png") or f.endswith(".qgz.png") for f in files), "QField thumbnails not uploaded")
    # QField's local copy must equal the server
    home = glob.glob(os.path.join(os.environ["S"], "qfhome", "Documents", "QField Documents", "Created Projects", "mm_mergin_dummy_points"))
    expect(len(home) == 1, "QField local project found")
    if home:
        local = home[0]
        expect(trees(os.path.join(local, "trees.gpkg")) == server, "QField local trees.gpkg equals the server")
        expect(trees(os.path.join(local, ".mergin", "trees.gpkg")) == server, "QField base copy equals the server")
        meta = json.load(open(os.path.join(local, ".mergin", "mergin.json")))
        expect(meta["version"] == info["version"], f"QField metadata version {meta['version']} == server {info['version']}")
        removed = os.path.join(local, "notes", "office.txt")
        expect(not os.path.exists(removed) or os.path.getsize(removed) == 0, "file removed on the server is gone or emptied in QField")
        tombstones = json.load(open(os.path.join(local, ".mergin", "removed.json")))
        expect("notes/office.txt" in tombstones, f"tombstone recorded {tombstones}")
        photo = os.path.join(local, "DCIM", "field_photo.jpg")
        srv_photo = [f for f in info["files"] if f["path"] == "DCIM/field_photo.jpg"]
        expect(bool(srv_photo) and hashlib.sha1(open(photo, "rb").read()).hexdigest() == srv_photo[0]["checksum"], "photo bytes identical on server")
    print("RESULT", "OK" if not failures else f"{len(failures)} FAILURES")
    sys.exit(1 if failures else 0)
