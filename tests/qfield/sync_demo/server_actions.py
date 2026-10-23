"""Screencast helper: reuses the sync E2E office actions (no final check)."""
import os, runpy, sys
if sys.argv[1] != "check":
    runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sync_e2e", "server_actions.py"), run_name="__main__")
