#!/usr/bin/env bash
podman rm -f mm-server mm-db merginmaps-redis merginmaps-web mm-proxy >/dev/null 2>&1; podman network rm mergin >/dev/null 2>&1; echo stopped
