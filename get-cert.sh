#!/usr/bin/env bash
# Issue a Let's Encrypt certificate for the EC2 public IP and set up auto-renewal.
# Run with: sudo ./get-cert.sh            (add --staging for a test run first)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"
source ./certbot.env
ip=$(grep -E '^PUBLIC_IP=' .env | cut -d= -f2)
[[ -n $ip ]] || { echo "PUBLIC_IP is empty in .env -- run setup-host.sh first." >&2; exit 1; }

mkdir -p "$WEBROOT/.well-known/acme-challenge" "$CERT_DIR"

# Check the existing Nginx serves the challenge path for the IP before asking Let's Encrypt.
echo ok > "$WEBROOT/.well-known/acme-challenge/selftest"
if [[ $(curl -s -m 5 "http://${ip}/.well-known/acme-challenge/selftest" || true) != ok ]]; then
  rm -f "$WEBROOT/.well-known/acme-challenge/selftest"
  echo "http://${ip}/.well-known/acme-challenge/ is not served from ${WEBROOT}." >&2
  echo "Install nginx/existing-nginx-acme-snippet.conf as /etc/nginx/conf.d/sonarqube-acme.conf (PUBLIC_IP filled in)," >&2
  echo "run 'sudo nginx -t && sudo systemctl reload nginx', and make sure port 80 is open in the Security Group." >&2
  exit 1
fi
rm -f "$WEBROOT/.well-known/acme-challenge/selftest"

# IP certificates need certbot >= 5.4 and the 6-day "shortlived" profile.
docker run --rm \
  -v "$CERT_DIR:/etc/letsencrypt" \
  -v "$CERT_DIR-log:/var/log/letsencrypt" \
  -v "$WEBROOT:$WEBROOT" \
  "$CERTBOT_IMAGE" certonly "$@" \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-profile shortlived \
  --webroot --webroot-path "$WEBROOT" \
  --ip-address "$ip"

# Certs last only 6 days, so renew twice a day with a systemd timer
# (Amazon Linux 2023 has no cron by default).
cat > /etc/systemd/system/certbot-sonarqube.service <<UNIT
[Unit]
Description=Renew SonarQube Let's Encrypt IP certificate
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$PWD/renew-cert.sh
UNIT
cat > /etc/systemd/system/certbot-sonarqube.timer <<'UNIT'
[Unit]
Description=Renew SonarQube IP certificate twice a day

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now certbot-sonarqube.timer

docker exec sonarqube-nginx nginx -s reload 2>/dev/null || true

echo "Certificate: $CERT_DIR/live/${ip}/fullchain.pem"
echo "Renewal timer: systemctl list-timers certbot-sonarqube.timer"
echo "Test renewal with: sudo ./renew-cert.sh --dry-run"
