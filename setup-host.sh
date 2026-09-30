#!/usr/bin/env bash
# One-time host preparation for SonarQube on EC2. Run with: sudo ./setup-host.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

cd "$(dirname "$0")"

# SonarQube's embedded Elasticsearch refuses to start without these kernel limits.
# Only ever raise them: the host default is usually far higher and the existing project shares it.
conf=/etc/sysctl.d/99-sonarqube.conf
: > "$conf"
if (( $(sysctl -n vm.max_map_count) < 524288 )); then echo "vm.max_map_count=524288" >> "$conf"; fi
if (( $(sysctl -n fs.file-max) < 131072 )); then echo "fs.file-max=131072" >> "$conf"; fi
# Load only this file; `sysctl --system` re-applies every distro file and prints unrelated errors.
sysctl -q -p "$conf"
echo "Kernel settings: vm.max_map_count=$(sysctl -n vm.max_map_count), fs.file-max=$(sysctl -n fs.file-max)"

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

# Measured with the existing project already running, so this is what is left for SonarQube.
# Swap is deliberately not counted: Elasticsearch and the JVMs become unusably slow when swapped,
# and they would push the existing project into swap too.
mem_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if (( mem_mb < 3000 )); then
  echo "WARNING: only ${mem_mb} MB RAM available (swap not counted). SonarQube needs ~2-3 GB of real RAM" >&2
  echo "on top of your existing project; resize the instance (8 GB recommended) or use a separate one." >&2
fi
