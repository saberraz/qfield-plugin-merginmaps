"""Server side of promo_shots: briefly pause the Mergin CE container so a sync is still running when the
"Synchronising" banner is photographed (a local sync otherwise finishes before the screenshot).
Usage (called by run_e2e.sh): python -I server_actions.py <pause|unpause|check> <work dir>
"""
import subprocess, sys

action = sys.argv[1]
if action in ("pause", "unpause"):
    subprocess.run(["podman", action, "mm-server"], check=True, capture_output=True)
    print("server", action + "d")
