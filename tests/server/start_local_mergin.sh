#!/usr/bin/env bash
# Starts a throwaway Mergin Maps CE server for tests, bound to 127.0.0.1:5000 only (podman).
# Only db + redis + API server: no celery, nginx or web app (USE_X_ACCEL=0 so the API serves downloads itself).
# Creates users fielduser / Field-Pass-123 (surveyor) and officeuser / Office-Pass-123 (admin, owns test projects).
# GLOBAL_WRITE=True: every user can read/write projects in the "mergin" workspace. Data lives in $MERGIN_TEST_DIR (default /tmp).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data="${MERGIN_TEST_DIR:-/tmp/mergin-test-server}"
image="docker.io/lutraconsulting/merginmaps-backend:${MERGIN_IMAGE_TAG:-2025.7.3}"
mkdir -p "$data/projects" && chmod 777 "$data/projects"
podman network exists mergin || podman network create mergin >/dev/null
podman rm -f mm-server mm-db merginmaps-redis merginmaps-web mm-proxy >/dev/null 2>&1 || true
podman run -d --replace --name mm-db --network mergin -e POSTGRES_DB=mergin -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres docker.io/library/postgres:14 >/dev/null
podman run -d --replace --name merginmaps-redis --network mergin docker.io/library/redis:6.2.17 >/dev/null
# a fresh Postgres needs several seconds to initialise; the API's /config answers before the DB is usable
for i in $(seq 60); do podman exec mm-db pg_isready -U postgres -d mergin >/dev/null 2>&1 && break; sleep 1; done
# the image's entrypoint expects the command as one string
podman run -d --replace --name mm-server --network mergin -p 127.0.0.1:5000:5000 --env-file "$here/local.env" \
  -v "$data/projects:/data:z" "$image" "gunicorn --config config.py application:application" >/dev/null
for i in $(seq 30); do curl -sf http://127.0.0.1:5000/config >/dev/null && break; sleep 1; done
podman exec mm-server flask init --email admin@example.com >/dev/null 2>&1 || true   # warns about celery/mail: expected
podman exec mm-server flask user create fielduser 'Field-Pass-123' --email field@example.com >/dev/null
podman exec mm-server flask user create officeuser 'Office-Pass-123' --is-admin --email office@example.com >/dev/null
# Optional Mergin Maps web dashboard (frontend + nginx proxy, as in the CE docker-compose) on 127.0.0.1:8080.
if [ -n "${WEB:-}" ]; then
  podman rm -f merginmaps-web mm-proxy >/dev/null 2>&1 || true
  podman run -d --replace --name merginmaps-web --network mergin "docker.io/lutraconsulting/merginmaps-frontend:${MERGIN_IMAGE_TAG:-2025.7.3}" >/dev/null
  podman run -d --replace --name mm-proxy --network mergin -p 127.0.0.1:8080:8080 -v "$data/projects:/data:z" \
    -v "$here/nginx-web.conf:/etc/nginx/conf.d/default.conf:z" docker.io/nginxinc/nginx-unprivileged:1.27 >/dev/null
  for i in $(seq 30); do curl -sf http://127.0.0.1:8080/ >/dev/null && break; sleep 1; done
  echo "Mergin web dashboard on http://127.0.0.1:8080"
fi
echo "Mergin test server $(curl -s http://127.0.0.1:5000/config | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])') on http://127.0.0.1:5000"
