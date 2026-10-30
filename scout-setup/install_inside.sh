#!/usr/bin/env bash
# install_inside.sh: step 1 inside the separate WSL distro "scout" (its disk lives in D:\scout\wsl).
# Installs MongoDB 8 (memory-capped, localhost only), Scout 4.115.2 in a venv, and a systemd
# service for the web server on http://localhost:8000. Run as root:
#   wsl -d scout -u root bash /mnt/c/NGS_pipeline/Claude_folder/scout-setup/install_inside.sh
set -euo pipefail
SCOUT_VERSION=4.115.2
MONGO_CACHE_GB=4          # WSL memory is shared with the pipeline; Mongo would otherwise take ~half of it
PORT=8000
HOME_DIR=/opt/scout

say() { printf '\e[1;36m>>\e[0m %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "запустите от root: wsl -d scout -u root bash $0"; exit 1; }

say "systemd и автоподключение дисков C:/D:"
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[automount]
enabled=true
EOF

say "пакеты Ubuntu (одна загрузка за раз)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q python3-venv tabix curl gnupg ca-certificates

say "MongoDB 8.0"
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg
echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-8.0.list
apt-get update -q
apt-get install -y -q mongodb-org
cat > /etc/mongod.conf <<EOF
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: $MONGO_CACHE_GB
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

say "Scout $SCOUT_VERSION в $HOME_DIR/venv"
mkdir -p "$HOME_DIR"
python3 -m venv "$HOME_DIR/venv"
"$HOME_DIR/venv/bin/pip" install -q --upgrade pip
"$HOME_DIR/venv/bin/pip" install -q "scout-browser==$SCOUT_VERSION" gunicorn pyyaml

if [ ! -f "$HOME_DIR/config.py" ]; then
  cat > "$HOME_DIR/config.py" <<EOF
SECRET_KEY = "$(head -c 32 /dev/urandom | base64 | tr -d '=+/')"
MONGO_DBNAME = "scout"
INSTANCE_NAME = "NGS lab"
BOOTSTRAP_SERVE_LOCAL = True
ACCREDITATION_BADGE = ""
REMEMBER_COOKIE_NAME = "scout_remember_me"
SESSION_TIMEOUT_MINUTES = 600
EOF
fi

cat > /etc/systemd/system/scout-web.service <<EOF
[Unit]
Description=Scout web (http://localhost:$PORT)
After=mongod.service
Requires=mongod.service

[Service]
Environment=SCOUT_CONFIG=$HOME_DIR/config.py
ExecStart=$HOME_DIR/venv/bin/gunicorn --workers 3 --threads 2 --timeout 400 --bind 127.0.0.1:$PORT scout.server.auto:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
ln -sf "$HOME_DIR/venv/bin/scout" /usr/local/bin/scout
systemctl enable mongod scout-web 2>/dev/null || true   # systemd starts them after the distro restarts

say "готово. Дальше: wsl --terminate scout, затем setup_db.sh"
