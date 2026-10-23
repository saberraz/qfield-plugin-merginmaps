"""Upload test projects to the local Mergin server with Lutra's official Python client (mergin-client).

Each sub-directory of <projects dir> becomes project mergin/<dir name>, owned by officeuser.
Usage: python -I seed_projects.py <projects dir> [server url]
"""
import os
import sys

from mergin import MerginClient

src = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:5000"
mc = MerginClient(url, login="officeuser", password="Office-Pass-123")
existing = {p["name"] for p in mc.projects_list(namespace="mergin")}
for name in sorted(os.listdir(src)):
    path = os.path.join(src, name)
    if not os.path.isdir(path) or name in existing:
        continue
    mc.create_project_and_push(f"mergin/{name}", path)
    info = mc.project_info(f"mergin/{name}")
    print(f"uploaded mergin/{name}: version {info['version']}, {len(info['files'])} files")
