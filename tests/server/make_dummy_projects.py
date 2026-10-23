"""Create dummy QGIS/QField projects for the local Mergin test server.

  dummy-points      one point layer (12 features) over the OpenStreetMap basemap: the simplest possible project
  dummy-edge-cases  awkward paths (spaces, Unicode, '&', nested folders), an empty layer, a layer without
                    geometry, and a GeoPackage larger than one 10 MB download chunk

Usage: python -I make_dummy_projects.py <out dir>      (needs GDAL Python bindings)
"""
import os
import random
import sys
from xml.sax.saxutils import escape

from osgeo import gdal, ogr, osr

gdal.UseExceptions()


def write_gpkg(path, layer_name, gtype, fields, rows, srs_epsg=4326):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    exists = os.path.exists(path)
    ds = ogr.Open(path, 1) if exists else ogr.GetDriverByName("GPKG").CreateDataSource(path)
    srs = None
    if gtype != ogr.wkbNone:
        srs = osr.SpatialReference(); srs.ImportFromEPSG(srs_epsg)
    lyr = ds.CreateLayer(layer_name, srs, gtype)
    for name, oft in fields:
        lyr.CreateField(ogr.FieldDefn(name, oft))
    ds.StartTransaction()
    for values, wkt in rows:
        f = ogr.Feature(lyr.GetLayerDefn())
        for k, v in values.items():
            f.SetField(k, v)
        if wkt:
            f.SetGeometry(ogr.CreateGeometryFromWkt(wkt))
        lyr.CreateFeature(f)
    ds.CommitTransaction()
    ds = None


def qgs(title, layers, extent):
    """QGIS project built from project_template.qgs, a file written by QField itself (QGIS 4.2.1, full CRS
    definitions, OpenStreetMap basemap). Hand-written minimal project XML loads but renders blank in QField.
    layers: vector layer dicts with name, source and optional geometry; drawn above the basemap in list order."""
    here = os.path.dirname(os.path.abspath(__file__))
    template = open(os.path.join(here, "project_template.qgs")).read().split("-->", 1)[1].lstrip()
    tree, maps, order = [], [], []
    for i, l in enumerate(layers):
        lid = f"vector_layer_{i}"
        src = escape(l["source"])
        geom = f' geometry="{l["geometry"]}"' if l.get("geometry") else ' geometry="No geometry"'
        # full CRS definition (all dummy data is EPSG:4326); without it the layer is not reprojected onto the map
        srs = open(os.path.join(here, "srs_4326.xml")).read().split("-->", 1)[1].strip() if l.get("geometry") else ""
        renderer = ""
        if l.get("geometry") == "Point":
            # without a renderer QGIS draws nothing; reuse a QGIS-written marker style
            renderer = open(os.path.join(here, "point_renderer.xml")).read().split("-->", 1)[1].strip()
        maps.append(f'''    <maplayer type="vector"{geom}>
      <id>{lid}</id><datasource>{src}</datasource><layername>{escape(l["name"])}</layername>
      {srs}
      <provider encoding="UTF-8">ogr</provider>
      {renderer}
    </maplayer>''')
        tree.append(f'<layer-tree-layer id="{lid}" name="{escape(l["name"])}" source="{src}" providerKey="ogr" checked="Qt::Checked" expanded="1"/>')
        order.append(f'<layer id="{lid}"/>')
    xmin, ymin, xmax, ymax = extent
    return (template.replace("__TITLE__", escape(title))
            .replace("__TREE__", "\n    ".join(tree))
            .replace("__MAPLAYERS__", "\n".join(maps))
            .replace("__ORDER__", "\n    ".join(order))
            .replace("__EXTENT__", f"<extent><xmin>{xmin}</xmin><ymin>{ymin}</ymin><xmax>{xmax}</xmax><ymax>{ymax}</ymax></extent>"))


def dummy_points(out):
    d = os.path.join(out, "dummy-points")
    r = random.Random(1)
    names = ["Oak", "Ash", "Beech", "Birch", "Lime", "Yew", "Holly", "Rowan", "Alder", "Willow", "Hazel", "Elm"]
    rows = [({"species": n, "height_m": round(r.uniform(3, 25), 1), "surveyor": "office"},
             f"POINT ({-0.1415 + r.uniform(-0.004, 0.004)} {50.8225 + r.uniform(-0.002, 0.002)})") for n in names]
    write_gpkg(os.path.join(d, "trees.gpkg"), "trees", ogr.wkbPoint,
               [("species", ogr.OFTString), ("height_m", ogr.OFTReal), ("surveyor", ogr.OFTString)], rows)
    layers = [{"name": "Trees", "source": "./trees.gpkg|layername=trees", "geometry": "Point"}]
    open(os.path.join(d, "dummy-points.qgs"), "w").write(qgs("Dummy points", layers, (-16210, 6589500, -15300, 6590100)))


def dummy_edge_cases(out):
    d = os.path.join(out, "dummy-edge-cases")
    r = random.Random(2)
    # nested folder, spaces, '&' and Unicode in file names
    sub = "data/trees & shrubs (2026).gpkg"
    rows = [({"name": f"Ž{i} ščé"}, f"POINT ({-0.14 + i * 1e-4} {50.82 + i * 1e-4})") for i in range(5)]
    write_gpkg(os.path.join(d, sub), "shrubs", ogr.wkbPoint, [("name", ogr.OFTString)], rows)
    # empty layer and an attribute-only table in the same GeoPackage
    write_gpkg(os.path.join(d, "survey.gpkg"), "empty_lines", ogr.wkbLineString, [("note", ogr.OFTString)], [])
    write_gpkg(os.path.join(d, "survey.gpkg"), "lookup", ogr.wkbNone, [("code", ogr.OFTString), ("label", ogr.OFTString)],
               [({"code": f"C{i}", "label": f"Label {i}"}, None) for i in range(20)])
    # > 10 MB so the download has to be split into several chunks
    big = [({"note": "x" * 200, "value": r.random()}, f"POINT ({r.uniform(-0.2, -0.1)} {r.uniform(50.8, 50.85)})") for _ in range(45000)]
    write_gpkg(os.path.join(d, "big/points_big.gpkg"), "points_big", ogr.wkbPoint, [("note", ogr.OFTString), ("value", ogr.OFTReal)], big)
    os.makedirs(os.path.join(d, "Fotky ščé"), exist_ok=True)
    with open(os.path.join(d, "Fotky ščé", "photo 1.jpg"), "wb") as fh:
        fh.write(bytes(r.randint(0, 255) for _ in range(5000)))   # binary, not a real image
    with open(os.path.join(d, "README.txt"), "w") as fh:
        fh.write("Dummy project exercising awkward paths and chunked downloads.\n")
    layers = [{"name": "Shrubs", "source": "./" + sub + "|layername=shrubs", "geometry": "Point"},
              {"name": "Lookup", "source": "./survey.gpkg|layername=lookup"},
              {"name": "Empty lines", "source": "./survey.gpkg|layername=empty_lines", "geometry": "Line"},
              {"name": "Big points", "kind": "vector", "source": "./big/points_big.gpkg|layername=points_big", "geometry": "Point"},
]
    open(os.path.join(d, "dummy-edge-cases.qgs"), "w").write(qgs("Dummy edge cases", layers, (-22300, 6584000, -11100, 6593000)))


if __name__ == "__main__":
    out = sys.argv[1]
    if out == "--demo-start":
        # start project for the screencast: just the basemap, centred on Europe
        open(sys.argv[2], "w").write(qgs("QField", [], (-1100000, 4300000, 3300000, 8000000)))
        sys.exit(0)
    dummy_points(out)
    dummy_edge_cases(out)
    for root, _, files in os.walk(out):
        for f in files:
            p = os.path.join(root, f)
            print(f"{os.path.getsize(p):>10}  {os.path.relpath(p, out)}")
