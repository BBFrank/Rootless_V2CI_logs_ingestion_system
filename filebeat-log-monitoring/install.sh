#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., using sudo)"
  exit 1
fi

# Absolute path to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Import environment variables
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "Missing environment file: ${SCRIPT_DIR}/.env"
  exit 1
fi
set -a
source "${SCRIPT_DIR}/.env"
set +a

: "${STACK_VERSION:?Define STACK_VERSION in ${SCRIPT_DIR}/.env}"
: "${ELASTIC_PASSWORD:?Define ELASTIC_PASSWORD in ${SCRIPT_DIR}/.env}"
: "${ES_PORT:?Define ES_PORT in ${SCRIPT_DIR}/.env}"
: "${KIBANA_PORT:?Define KIBANA_PORT in ${SCRIPT_DIR}/.env}"

# Add Docker's official GPG key:
echo "Updating package database and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg sshpass
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

# Install Docker packages and dependencies:
echo "Installing Docker packages..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Pull the Filebeat image
echo "Pulling and verifying Filebeat Docker image..."
docker pull docker.elastic.co/beats/filebeat:${STACK_VERSION}

# Append in /etc/hosts the elastic host ip (from env variable) as elasticsearch and kibana
echo "Updating /etc/hosts file..."
HOST_ALIASES="elasticsearch logstash kibana v2ci-es-master-1 v2ci-es-master-2 v2ci-es-master-3 v2ci-es-hot-1 v2ci-logstash v2ci-kibana"
if ! grep -q "v2ci-logstash" /etc/hosts; then
  echo "Adding Elastic Stack hostnames to /etc/hosts..."
  echo "$ELASTIC_HOST_IP $HOST_ALIASES" | sudo tee -a /etc/hosts >/dev/null
else
  echo "Elastic Stack hostnames already present in /etc/hosts. Skipping..."
fi

# Copy the crt file to ./certs
echo "Copying certificate file..."
mkdir -p ${SCRIPT_DIR}/certs
if [ ! -f "${SCRIPT_DIR}/certs/ca.crt" ]; then
  CERT_SOURCE_HOST="${ELASTIC_HOST_IP_SCP:-$ELASTIC_HOST_IP}"
  CERT_SOURCE_PATH="${ELASTIC_CERTS_DIR}/ca/ca.crt"
  if [[ -n "${ELASTIC_STACK_HOST_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${ELASTIC_STACK_HOST_PASSWORD}" scp -o StrictHostKeyChecking=no ${ELASTIC_USER}@${CERT_SOURCE_HOST}:${CERT_SOURCE_PATH} ${SCRIPT_DIR}/certs/ca.crt
  else
    scp -o StrictHostKeyChecking=no ${ELASTIC_USER}@${CERT_SOURCE_HOST}:${CERT_SOURCE_PATH} ${SCRIPT_DIR}/certs/ca.crt
  fi
  if [ ! -f "${SCRIPT_DIR}/certs/ca.crt" ]; then
    echo "Failed to copy certificate from ${ELASTIC_USER}@${CERT_SOURCE_HOST}:${CERT_SOURCE_PATH}. Aborting." >&2
    exit 1
  fi
else
    echo "Certificate file already exists. Skipping copy..."
fi
sudo chmod 644 ${SCRIPT_DIR}/certs/ca.crt

# Run filebeat setup
echo "Setting up Filebeat..."
docker run --rm \
  --volume="${SCRIPT_DIR}/certs:/usr/share/filebeat/certs:ro" \
  --add-host="v2ci-kibana:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-1:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-2:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-3:${ELASTIC_HOST_IP}" \
  docker.elastic.co/beats/filebeat:${STACK_VERSION} \
  setup \
  -E output.logstash.enabled=false \
  -E setup.kibana.host=https://v2ci-kibana:${KIBANA_PORT} \
  -E setup.kibana.ssl.certificate_authorities=["/usr/share/filebeat/certs/ca.crt"] \
  -E setup.template.overwrite=true \
  -E setup.template.settings.index.number_of_replicas=0 \
  -E output.elasticsearch.hosts=["https://v2ci-es-master-1:${ES_PORT}","https://v2ci-es-master-2:${ES_PORT}","https://v2ci-es-master-3:${ES_PORT}"] \
  -E output.elasticsearch.ssl.certificate_authorities=["/usr/share/filebeat/certs/ca.crt"] \
  -E output.elasticsearch.username=elastic \
  -E output.elasticsearch.password=${ELASTIC_PASSWORD}

# Writing the unit file for filebeat
echo "Creating systemd service for Filebeat..."
sudo chmod +x ${SCRIPT_DIR}/start.sh
sudo chmod +x ${SCRIPT_DIR}/stop.sh
sudo tee /etc/systemd/system/v2ci-filebeat.service >/dev/null <<EOF
[Unit]
Description=Filebeat for v2ci
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/start.sh
ExecStop=${SCRIPT_DIR}/stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the filebeat service
echo "Starting Filebeat service..."
sudo systemctl daemon-reload
sudo systemctl start v2ci-filebeat.service

echo "Elastic Stack service is up and running."
echo "Open Kibana at: https://v2ci-kibana:${KIBANA_PORT}"

echo "Installation and setup complete."