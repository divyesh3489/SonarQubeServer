# SonarQube on EC2 (Docker, public IP only)

Runs SonarQube Community + PostgreSQL next to an existing project on the same EC2 host.
SonarQube is reached only at `https://<EC2_PUBLIC_IP>:9000`. It is **not** added to the existing
project's Nginx/domain config, so that project is untouched.

A dedicated Nginx container sits in front of SonarQube and only accepts requests whose Host is the
public IP. Requests via the existing project's domain (e.g. `http://yourdomain.com:9000`) are dropped.

```
browser -> https :9000 -> sonarqube-nginx (Let's Encrypt IP cert) (Host == PUBLIC_IP?) -> sonarqube:9000 -> postgres
```

## Requirements
- Docker + Docker Compose plugin on the EC2 instance
- certbot >= 5.4 (`sudo snap install --classic certbot`) -- needed for IP address certificates
- Port 80 open to the internet (Let's Encrypt validates the IP over HTTP; your existing project likely has this already)
- ~2-3 GB free RAM for SonarQube (t3.medium or larger recommended when sharing the host)

## Deploy
```bash
# copy this folder to the EC2 instance, then:
cd SonarQube
chmod +x setup-host.sh
sudo ./setup-host.sh          # kernel limits, creates .env, detects PUBLIC_IP, checks port is free
nano .env                     # set a strong POSTGRES_PASSWORD; verify PUBLIC_IP (and SONAR_PORT if 9000 is taken)
```

### HTTPS certificate (Let's Encrypt for the bare IP)
Let's Encrypt validates the IP via `http://<EC2_PUBLIC_IP>/.well-known/acme-challenge/`, and port 80 is
owned by your existing Nginx. Add the block from `nginx/existing-nginx-acme-snippet.conf` to that
Nginx (it only matches the bare IP, so your domain is unaffected), then:
```bash
sudo nginx -t && sudo systemctl reload nginx   # existing Nginx
sudo ./get-cert.sh --staging                   # optional test against LE staging
sudo ./get-cert.sh                             # real certificate
sudo certbot renew --dry-run                   # confirm auto-renewal works
```
IP certificates are only valid for **6 days**. certbot's timer renews them automatically and the
deploy hook reloads the `sonarqube-nginx` container, so nothing manual is needed once it works.

### Start SonarQube
```bash
docker compose up -d
docker compose logs -f sonarqube   # wait for "SonarQube is operational"
```

## Open the port in AWS
EC2 -> Security Groups -> the instance's group -> Inbound rules -> Add rule:
- Type: Custom TCP, Port: `9000` (or your `SONAR_PORT`)
- Source: **My IP** (recommended) or your office/CI IP range; avoid `0.0.0.0/0` if possible

If `ufw` is enabled on the instance: `sudo ufw allow 9000/tcp`

## Access
`https://<EC2_PUBLIC_IP>:9000` — default login `admin` / `admin` (you are forced to change it on first login).

Tip: attach an **Elastic IP** to the instance, otherwise the public IP changes on stop/start.
If the IP changes, update `PUBLIC_IP` in `.env`, the existing-Nginx snippet, re-run `sudo ./get-cert.sh`, then `docker compose up -d`.

## Useful commands
```bash
docker compose ps
docker compose logs -f sonarqube
docker compose down        # stop (data kept in volumes)
docker compose pull && docker compose up -d   # upgrade
```

## Scanning a project
```bash
docker run --rm -e SONAR_HOST_URL="https://<EC2_PUBLIC_IP>:9000" \
  -e SONAR_TOKEN="<token from My Account -> Security>" \
  -v "$PWD:/usr/src" sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=my-project
```
