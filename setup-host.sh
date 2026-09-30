#!/usr/bin/env bash
# One-time host preparation for SonarQube on EC2. Run with: sudo ./setup-host.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

cd "$(dirname "$0")"

# SonarQube's embedded Elasticsearch refuses to start without these kernel limits.
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system >/dev/null
echo "Kernel settings applied: vm.max_map_count=$(sysctl -n vm.max_map_count), fs.file-max=$(sysctl -n fs.file-max)"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example -- edit POSTGRES_PASSWORD before starting."
fi

# Fill PUBLIC_IP from EC2 instance metadata (IMDSv2) if it is not set yet.
if ! grep -qE '^PUBLIC_IP=.+' .env; then
  token=$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
  ip=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || true)
  if [[ $ip =~ ^[0-9.]+$ ]]; then
    sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=${ip}/" .env
    echo "PUBLIC_IP set to ${ip}"
  else
    echo "WARNING: could not detect public IP -- set PUBLIC_IP in .env manually." >&2
  fi
fi

# Make sure the chosen port is not taken by the project already running on this host.
port=$(grep -E '^SONAR_PORT=' .env | cut -d= -f2)
if ss -ltn "sport = :${port}" | grep -q LISTEN; then
  echo "WARNING: port ${port} is already in use on this host:" >&2
  ss -ltnp "sport = :${port}" >&2
  echo "Change SONAR_PORT in .env to a free port (e.g. 9001)." >&2
  exit 1
fi
echo "Port ${port} is free."

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( mem_mb < 3500 )); then
  echo "WARNING: only ${mem_mb} MB RAM. SonarQube needs ~2-3 GB on top of your existing project; use t3.medium or larger, or add swap." >&2
fi
