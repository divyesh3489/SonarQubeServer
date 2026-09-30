#!/usr/bin/env bash
# Renew the SonarQube IP certificate (run twice a day by certbot-sonarqube.timer) and reload
# the SonarQube Nginx container. Manual test: sudo ./renew-cert.sh --dry-run
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
source ./certbot.env

docker run --rm \
  -v "$CERT_DIR:/etc/letsencrypt" \
  -v "$CERT_DIR-log:/var/log/letsencrypt" \
  -v "$WEBROOT:$WEBROOT" \
  "$CERTBOT_IMAGE" renew -q "$@"

# Cheap and harmless when nothing was renewed; skipped if SonarQube isn't running.
docker exec sonarqube-nginx nginx -s reload 2>/dev/null || true
