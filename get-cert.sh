#!/usr/bin/env bash
# Issue a Let's Encrypt certificate for the EC2 public IP and set up auto-renewal.
# Run with: sudo ./get-cert.sh            (add --staging for a test run first)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

cd "$(dirname "$0")"
ip=$(grep -E '^PUBLIC_IP=' .env | cut -d= -f2)
[[ -n $ip ]] || { echo "PUBLIC_IP is empty in .env -- run setup-host.sh first." >&2; exit 1; }

# IP address certificates need certbot >= 5.4 (--ip-address with webroot).
# Amazon Linux has no snap and its dnf certbot is too old, so use the official pip install.
install_hint() {
  cat >&2 <<'HINT'
Install certbot >= 5.4 (Amazon Linux, official pip method). Keeps existing certs in /etc/letsencrypt:
  sudo dnf remove -y certbot python3-certbot-nginx
  sudo python3 -m venv /opt/certbot
  sudo /opt/certbot/bin/pip install --upgrade pip certbot certbot-nginx
  sudo ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
(This script installs a twice-daily renewal timer itself.)
HINT
}
if ! command -v certbot >/dev/null; then
  echo "certbot not found." >&2
  install_hint
  exit 1
fi
ver=$(certbot --version 2>&1 | awk '{print $2}')
if [[ $(printf '%s\n' 5.4 "$ver" | sort -V | head -1) != 5.4 ]]; then
  echo "certbot $ver is too old (need >= 5.4)." >&2
  install_hint
  exit 1
fi

webroot=/var/www/certbot
mkdir -p "$webroot"

# Check the existing Nginx serves the challenge path for the IP before asking Let's Encrypt.
mkdir -p "$webroot/.well-known/acme-challenge"
echo ok > "$webroot/.well-known/acme-challenge/selftest"
if [[ $(curl -s -m 5 "http://${ip}/.well-known/acme-challenge/selftest" || true) != ok ]]; then
  rm -f "$webroot/.well-known/acme-challenge/selftest"
  echo "http://${ip}/.well-known/acme-challenge/ is not served from ${webroot}." >&2
  echo "Install nginx/existing-nginx-acme-snippet.conf as /etc/nginx/conf.d/sonarqube-acme.conf (PUBLIC_IP filled in)," >&2
  echo "run 'sudo nginx -t && sudo systemctl reload nginx', and make sure port 80 is open in the Security Group." >&2
  exit 1
fi
rm -f "$webroot/.well-known/acme-challenge/selftest"

# Certs last 6 days; certbot's systemd timer / snap timer renews them automatically,
# and the deploy hook makes the SonarQube Nginx container pick up the new files.
certbot certonly "$@" \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-profile shortlived \
  --webroot --webroot-path "$webroot" \
  --ip-address "$ip" \
  --deploy-hook "docker exec sonarqube-nginx nginx -s reload || true"

# IP certs last only 6 days, so renew twice a day with a systemd timer (Amazon Linux 2023 has no
# cron by default, and removing dnf's certbot removes its timer). Renews every cert in
# /etc/letsencrypt, including the existing domain cert -- running alongside another renewer is harmless.
cat > /etc/systemd/system/certbot-renew-ip.service <<'UNIT'
[Unit]
Description=Renew Let's Encrypt certificates (incl. SonarQube IP cert)

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew -q
UNIT
cat > /etc/systemd/system/certbot-renew-ip.timer <<'UNIT'
[Unit]
Description=Run certbot renew twice a day

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now certbot-renew-ip.timer

echo "Certificate: /etc/letsencrypt/live/${ip}/fullchain.pem"
echo "Renewal timer: systemctl list-timers certbot-renew-ip.timer"
echo "Test renewal with: sudo certbot renew --dry-run"
