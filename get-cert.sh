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
if ! command -v certbot >/dev/null; then
  echo "certbot not found. Install it with: sudo snap install --classic certbot && sudo ln -sf /snap/bin/certbot /usr/bin/certbot" >&2
  exit 1
fi
ver=$(certbot --version 2>&1 | awk '{print $2}')
if [[ $(printf '%s\n' 5.4 "$ver" | sort -V | head -1) != 5.4 ]]; then
  echo "certbot $ver is too old (need >= 5.4). Replace the apt version with the snap one:" >&2
  echo "  sudo apt remove certbot && sudo snap install --classic certbot && sudo ln -sf /snap/bin/certbot /usr/bin/certbot" >&2
  echo "Existing certificates in /etc/letsencrypt are kept and keep renewing." >&2
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
  echo "Add nginx/existing-nginx-acme-snippet.conf to your existing Nginx, reload it, and make sure port 80 is open." >&2
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

echo "Certificate: /etc/letsencrypt/live/${ip}/fullchain.pem"
echo "Test renewal with: sudo certbot renew --dry-run"
