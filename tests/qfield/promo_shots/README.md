# Screenshots and announcement slides

Not a test: regenerates the screenshots and LinkedIn-style slides (1080×1350) from the real UI.

1. Local CE server with the dashboard (`WEB=1 tests/server/start_local_mergin.sh`, then `prepare_test_projects.sh`) and the mock multi-workspace server on port 5055.
2. A 1080×2160 X display: `Xwayland :99 -geometry 1080x2160` (or `Xvfb :99 -screen 0 1080x2160x24`).
3. `QT_SCALE_FACTOR=2 S=<work dir> PYTHON=<py> E2E_TIMEOUT=240 tests/qfield/run_e2e.sh promo_shots`: QField screenshots in `$S/e2e/promo_shots/screenshots`.
4. `python tools/dashboard_shots.py <dir>`: page-only dashboard screenshots of QField's first push (headless Chrome; needs `websocket-client`).
5. `SHOTS=… DASH=<dir> OUT=<dir> python tools/compose_slides.py`: slides plus a PDF for a LinkedIn document post (needs Pillow).
