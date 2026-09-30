#!/bin/bash
# Runs once as root on first boot: prepares the box to receive release bundles.
set -eux

apt-get update -y
apt-get install -y python3 python3-venv curl

useradd --system --create-home --home-dir /opt/notesy --shell /usr/sbin/nologin notesy || true
mkdir -p /opt/notesy/releases /opt/notesy/data /etc/notesy
chown -R notesy:notesy /opt/notesy

if [ ! -f /etc/notesy/notesy.env ]; then
  cat > /etc/notesy/notesy.env <<ENV
DJANGO_DEBUG=False
DJANGO_SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1
DATABASE_URL=sqlite:////opt/notesy/data/db.sqlite3
ENV
  chown root:notesy /etc/notesy/notesy.env
  chmod 640 /etc/notesy/notesy.env
fi

cat > /etc/systemd/system/notesy.service <<'UNIT'
[Unit]
Description=Notesy (gunicorn)
After=network.target

[Service]
User=notesy
Group=notesy
WorkingDirectory=/opt/notesy/current
EnvironmentFile=/etc/notesy/notesy.env
ExecStart=/opt/notesy/current/.venv/bin/gunicorn notesy.wsgi:application --bind 0.0.0.0:8000 --workers 2 --access-logfile -
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable notesy   # starts for real after the first pipeline deploy creates /opt/notesy/current