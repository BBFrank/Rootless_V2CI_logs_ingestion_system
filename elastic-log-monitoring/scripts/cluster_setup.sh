#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="config/certs"
CA_CERT="${CERT_DIR}/ca/ca.crt"
STACK_UID=1000   # elasticsearch, logstash and kibana share the same UID in official images
STACK_GID=0      # elastic-stack containers run with root as primary group

log() {
  echo "$@"
}

require_var() {
  local name="$1"
  local value="${!1:-}"
  if [[ -z "$value" ]]; then
    log "Set the ${name} environment variable in the .env file"
    exit 1
  fi
}

require_var "ELASTIC_PASSWORD"
require_var "KIBANA_PASSWORD"
require_var "ES_PORT"

ES_HOST="https://v2ci-es-master-1:${ES_PORT}"

if [[ ! -f "${CERT_DIR}/ca.zip" ]]; then
  log "Creating CA"
  bin/elasticsearch-certutil ca --silent --pem -out "${CERT_DIR}/ca.zip"
  unzip "${CERT_DIR}/ca.zip" -d "${CERT_DIR}"
fi

if [[ ! -f "${CERT_DIR}/certs.zip" ]]; then
  log "Creating certs"
  bin/elasticsearch-certutil cert \
    --silent \
    --pem \
    -out "${CERT_DIR}/certs.zip" \
    --in "${CERT_DIR}/instances.yml" \
    --ca-cert "${CERT_DIR}/ca/ca.crt" \
    --ca-key "${CERT_DIR}/ca/ca.key"
  unzip "${CERT_DIR}/certs.zip" -d "${CERT_DIR}"
fi


log "Setting file permissions"
chown -R "${STACK_UID}:${STACK_GID}" "${CERT_DIR}"
find "${CERT_DIR}" -type d -exec chmod 0755 {} \;
find "${CERT_DIR}" -type f -name "*.crt" -exec chmod 0644 {} \;
find "${CERT_DIR}" -type f -name "*.pem" -exec chmod 0644 {} \;
find "${CERT_DIR}" -type f -name "*.key" -exec chmod 0640 {} \;
chmod 0644 "${CA_CERT}" || true

log "Waiting for Elasticsearch availability"
until curl -s --cacert "${CA_CERT}" "${ES_HOST}" | grep -q "missing authentication credentials"; do
  sleep 30
done

log "Setting cluster default index.number_of_replicas=0"
curl --cacert "${CA_CERT}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -X PUT "${ES_HOST}/_template/default" \
  -d @- <<'JSON'
{
  "index_patterns": ["*"],
  "settings": {
    "number_of_replicas": 0
  }
}
JSON

log "Setting kibana_system password"
until curl -s -X POST --cacert "${CA_CERT}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${ES_HOST}/_security/user/kibana_system/_password" \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}" | grep -q '^{}'; do
  sleep 10
done

log "Set ILM policies with ILM_setup.sh script"
bash /usr/share/elasticsearch/ILM_setup.sh || log "ILM script failed"

log "All done!"
