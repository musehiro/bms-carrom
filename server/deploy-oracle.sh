#!/bin/bash
# BMS Carrom server — Oracle Cloud Always Free VM setup (Ubuntu 22.04).
# Run ON the VM as the ubuntu user, AFTER the Oracle account is created
# (account + card verification are done by Buddhika in the browser —
# this script does not create any account or touch any payment details).
#
# What it does:
#   1. Installs unzip + downloads the Godot 4.3 headless binary.
#   2. Clones the public bms-carrom repo and keeps only server/.
#   3. Opens UDP 8910 in the VM firewall (ufw).
#      (You must ALSO open UDP 8910 in the Oracle security list:
#       VCN -> Security Lists -> Ingress Rule, UDP, port 8910, 0.0.0.0/0.)
#   4. Installs + starts a systemd service so the server restarts on boot.
#
# Usage:
#   chmod +x deploy-oracle.sh
#   ./deploy-oracle.sh
# Then check:  sudo systemctl status carrom-server
# And note the VM's public IP for the game's NEARBY -> INTERNET SERVER field.

set -euo pipefail
GODOT_URL="https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip"
REPO="https://github.com/musehiro/bms-carrom.git"
INSTALL_DIR="$HOME/bms-carrom-server"
GODOT_BIN="$HOME/godot"

echo "== BMS Carrom server setup =="
sudo apt-get update -qq
sudo apt-get install -y -qq unzip git ufw > /dev/null

if [ ! -x "$GODOT_BIN" ]; then
  echo "-- downloading Godot 4.3 headless..."
  cd "$HOME"
  wget -q "$GODOT_URL" -O godot.zip
  unzip -o -q godot.zip
  chmod +x Godot_v4.3-stable_linux.x86_64
  mv Godot_v4.3-stable_linux.x86_64 "$GODOT_BIN"
  rm -f godot.zip
else
  echo "-- Godot binary already present, skipping download."
fi

echo "-- getting the server code..."
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull -q
else
  rm -rf "$INSTALL_DIR" /tmp/bms-carrom-clone
  git clone -q --depth 1 "$REPO" /tmp/bms-carrom-clone
  mkdir -p "$INSTALL_DIR"
  cp -r /tmp/bms-carrom-clone/server/. "$INSTALL_DIR/"
  rm -rf /tmp/bms-carrom-clone
fi

echo "-- opening UDP 8910 in the VM firewall..."
sudo ufw allow 8910/udp > /dev/null || true
sudo ufw --force enable > /dev/null || true

echo "-- installing systemd service..."
sudo tee /etc/systemd/system/carrom-server.service > /dev/null <<EOF
[Unit]
Description=BMS Carrom server
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$GODOT_BIN --headless --path $INSTALL_DIR -- --port 8910
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable carrom-server > /dev/null
sudo systemctl restart carrom-server
sleep 3
sudo systemctl status carrom-server --no-pager | head -12
echo
echo "== Done. Server should be listening on UDP 8910. =="
echo "Public IP: $(curl -s --max-time 10 https://ipinfo.io/ip || echo '<could not detect — check the Oracle console>')"
echo "Remember to open UDP 8910 in the Oracle security list too (see header)."
echo "Then type this IP into the game: PLAY -> NEARBY -> INTERNET SERVER -> SAVE."
