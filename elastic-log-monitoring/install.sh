#!/bin/bash
set -euo pipefail

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., using sudo)"
  exit 1
fi

# Path assoluto della repo (indipendente dalla cwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${SCRIPT_DIR}"

if [ ! -f "${PROJ_DIR}/.env" ]; then
  echo "Missing environment file: ${PROJ_DIR}/.env"
  exit 1
fi
set -a
source "${PROJ_DIR}/.env"
set +a

: "${KIBANA_PORT:?Define KIBANA_PORT in ${PROJ_DIR}/.env}"

# Add Docker's official GPG key:
echo "Updating package database and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo "Adding Docker repository to APT sources..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y

# Install Docker packages, lvm (for containers' storage driver) and filesystem/quota tooling
echo "Installing Docker packages..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin lvm2 e2fsprogs xfsprogs quota

# Install the images (elasticsearch, kibana, logstash)
echo "Pulling Elasticsearch, Kibana, and Logstash Docker images..."
cd ${PROJ_DIR}
sudo docker compose pull
echo "Installation completed."

# Writing elastic-stack.service systemd file
echo "Creating elastic-stack systemd service..."
sudo chmod +x ${PROJ_DIR}/scripts/LVM_setup.sh ${PROJ_DIR}/scripts/LVM_teardown.sh
sudo tee /etc/systemd/system/elastic-stack.service >/dev/null <<EOF
[Unit]
Description=Containerized Elastic Stack
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=${PROJ_DIR}
ExecStartPre=${PROJ_DIR}/scripts/LVM_setup.sh
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecStopPost=${PROJ_DIR}/scripts/LVM_teardown.sh
ExecReload=/usr/bin/docker compose restart

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the elastic-stack service
echo "Starting elastic-stack service..."
sudo systemctl daemon-reload
sudo systemctl start elastic-stack

# Wait for the CA to be generated and import it into the host's trust store
echo "Waiting for Elastic CA (${PROJ_DIR}/certs/ca/ca.crt) to be generated..."
CA_SRC="${PROJ_DIR}/certs/ca/ca.crt"
for i in {1..300}; do
  if [ -r "${CA_SRC}" ]; then
    echo "CA found. Installing into host trust store..."
    sudo install -D -m 0644 "${CA_SRC}" /usr/local/share/ca-certificates/elastic-stack-ca.crt
    if command -v update-ca-certificates >/dev/null 2>&1; then
      sudo update-ca-certificates
    fi
    echo "Host trust store updated."
    break
  fi
  sleep 2
done

# Map the hostname to match the certificate (Subject/SAN: v2ci-kibana)
if ! grep -qE '(^|[[:space:]])v2ci-kibana([[:space:]]|$)' /etc/hosts; then
  echo "Adding v2ci-kibana to /etc/hosts"
  echo "127.0.0.1 v2ci-kibana" | sudo tee -a /etc/hosts >/dev/null
fi

echo "Elastic Stack service is up and running."
echo "Open Kibana at: https://v2ci-kibana:${KIBANA_PORT}"
