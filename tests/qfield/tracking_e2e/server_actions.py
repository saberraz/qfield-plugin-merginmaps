"""Server side of tracking_e2e: a Mergin project with a tracking layer, a colleague's track, and the checks.

Usage (called by run_e2e.sh): python -I server_actions.py <action> <work dir>
  setup          (re)create mergin/tracking-e2e from mergin_project/ (tracking layer as the QGIS Mergin plugin sets it up)
  office_track   officeuser adds a finished track and pushes: it takes the same new feature id as the track QField is
                 recording, so QField's next sync must rebase (renumber) its track and keep tracking on it
  check_partial  after a sync during tracking: the server has QField's track so far, attributes set (-> partial.json)
  check          final: complete track, continuous M, attributes, colleague's track intact, project file unchanged
"""
import datetime, glob, hashlib, json, math, os, re, shutil, sys, tempfile

from mergin import MerginClient
from osgeo import ogr

ogr.UseExceptions()
PROJECT = "mergin/tracking-e2e"
here = os.path.dirname(os.path.abspath(__file__))
action, work = sys.argv[1], sys.argv[2]
mc = MerginClient("http://127.0.0.1:5000", login="officeuser", password="Office-Pass-123")


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def server_copy():
    d = tempfile.mkdtemp()
    shutil.rmtree(d)
    mc.download_project(PROJECT, d)
    return d


def tracks(gpkg):
    ds = ogr.Open(gpkg)
    out = []
    for f in ds.GetLayer(0):
        g = f.GetGeometryRef()
        n = g.GetPointCount() if g else 0
        out.append({"fid": f.GetFID(), "tracked_by": f.GetField("tracked_by"),
                    "start": f.GetFieldAsISO8601DateTime("tracking_start_time") if f.IsFieldSetAndNotNull("tracking_start_time") else None,
                    "end": f.GetFieldAsISO8601DateTime("tracking_end_time") if f.IsFieldSetAndNotNull("tracking_end_time") else None,
                    "distance": f.GetField("total_distance"), "vertices": n,
                    "m": [g.GetM(i) for i in range(n)], "metres": geodesic_length(g) if g else 0})
    ds = None
    return out


def geodesic_length(g):
    """Length in metres of a lon/lat line (haversine on the mean Earth radius; QGIS uses the WGS84 ellipsoid)."""
    total = 0.0
    for i in range(g.GetPointCount() - 1):
        lon1, lat1, lon2, lat2 = map(math.radians, (g.GetX(i), g.GetY(i), g.GetX(i + 1), g.GetY(i + 1)))
        a = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
        total += 2 * 6371008.8 * math.asin(math.sqrt(a))
    return total


def first_point_ms():
    """The first recorded point's time, logged by the QField driver."""
    found = re.findall(r"E2E INFO first_point_ms=(\d+)", open(os.path.join(work, "qfield.log"), errors="replace").read())
    return int(found[0]) if found else None


def iso_ms(text):
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() * 1000)


if action == "setup":
    if any(p["name"] == "tracking-e2e" for p in mc.projects_list(namespace="mergin")):
        mc.delete_project_now(PROJECT)
    src = tempfile.mkdtemp()
    for f in ("tracking-project.qgs", "tracking_layer.gpkg"):
        shutil.copy(os.path.join(here, "mergin_project", f), src)
    mc.create_project_and_push(PROJECT, src)
    print("created", PROJECT, mc.project_info(PROJECT)["version"])

elif action == "office_track":
    office = os.path.join(work, "office")
    mc.download_project(PROJECT, office)
    ds = ogr.Open(os.path.join(office, "tracking_layer.gpkg"), 1)
    lyr = ds.GetLayer(0)
    f = ogr.Feature(lyr.GetLayerDefn())
    line = ogr.Geometry(ogr.wkbLineStringZM)
    for i in range(5):
        line.AddPointZM(9.25 + i * 0.0001, 46.80, 1060.0, float(i))
    f.SetGeometry(line)
    f.SetField("tracked_by", "officeuser")
    f.SetField("tracking_start_time", "2026-10-23T08:00:00Z")
    f.SetField("tracking_end_time", "2026-10-23T08:05:00Z")
    f.SetField("total_distance", 0.0)
    lyr.CreateFeature(f)
    print("office track fid", f.GetFID())
    ds = None
    mc.push_project(office)
    print("office_track pushed", mc.project_info(PROJECT)["version"])

elif action == "check_partial":
    d = server_copy()
    t = tracks(os.path.join(d, "tracking_layer.gpkg"))
    json.dump(t, open(os.path.join(work, "partial.json"), "w"))
    print("partial", json.dumps([{k: v for k, v in x.items() if k != "m"} for x in t]))

elif action == "check":
    failures = []

    def expect(cond, what):
        print(("PASS " if cond else "FAIL ") + what)
        if not cond:
            failures.append(what)

    d = server_copy()
    info = mc.project_info(PROJECT)
    final = tracks(os.path.join(d, "tracking_layer.gpkg"))
    partial = json.load(open(os.path.join(work, "partial.json"))) if os.path.exists(os.path.join(work, "partial.json")) else []
    print("server version", info["version"])
    print("final", json.dumps([{k: v for k, v in x.items() if k != "m"} for x in final]))
    ours = [x for x in final if x["tracked_by"] == "fielduser"]
    office = [x for x in final if x["tracked_by"] == "officeuser"]
    expect(len(ours) == 1, f"exactly one QField track on the server ({len(ours)})")
    expect(len(office) == 1 and office[0]["vertices"] == 5, "colleague's track intact")
    if ours:
        t = ours[0]
        p = [x for x in partial if x["tracked_by"] == "fielduser"]
        expect(len(p) == 1, "the sync during tracking already uploaded the track")
        if p:
            expect(p[0]["start"] and p[0]["end"] and p[0]["distance"] is not None, "partial track had start, end and distance")
            expect(t["vertices"] > p[0]["vertices"], f"tracking continued after the sync ({p[0]['vertices']} -> {t['vertices']} vertices)")
            expect(t["m"][:p[0]["vertices"]] == p[0]["m"], "the uploaded part was kept unchanged")
        # the first vertex's time: its M when QField stored epoch seconds (QField's "elapsed time" without a session
        # start, see MerginTracking.firstPointTime), otherwise the tracker's session start logged by the driver
        fp = t["m"][0] * 1000 if t["m"] and t["m"][0] > 1e9 else first_point_ms()
        expect(fp is not None and t["start"] and abs(iso_ms(t["start"]) - fp) < 1500,
               f"start time = first recorded point ({t['start']} vs {fp})")
        expect(t["end"] and iso_ms(t["end"]) > iso_ms(t["start"]) + 20000, f"end time after the start ({t['end']})")
        expect(t["distance"] is not None and abs(t["distance"] - t["metres"]) <= max(0.5, 0.01 * t["metres"]),
               f"total_distance = the layer's round($length, 2), metres ({t['distance']} vs {t['metres']:.2f})")
        m = t["m"]
        expect(all(b >= a for a, b in zip(m, m[1:])), f"M (elapsed seconds) never goes back: {m[:3]} ... {m[-3:]}")
        expect(m[-1] >= 30, f"M kept counting from the start across syncs (last {m[-1]})")
    project_file = os.path.join(d, "tracking-project.qgs")
    expect(sha1(project_file) == sha1(os.path.join(here, "mergin_project", "tracking-project.qgs")),
           "project file unchanged (variables stay in memory)")
    mc.delete_project_now(PROJECT)
    sys.exit(1 if failures else 0)
