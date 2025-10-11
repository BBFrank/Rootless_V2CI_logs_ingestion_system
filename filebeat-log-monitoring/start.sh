#!/bin/bash

# Absolute path to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Import environment variables
source "${SCRIPT_DIR}/.env"

: "${STACK_VERSION:?Define STACK_VERSION in ${SCRIPT_DIR}/.env}"
: "${LOGSTASH_PORT:?Define LOGSTASH_PORT in ${SCRIPT_DIR}/.env}"
: "${KIBANA_PORT:?Define KIBANA_PORT in ${SCRIPT_DIR}/.env}"
: "${ES_PORT:?Define ES_PORT in ${SCRIPT_DIR}/.env}"
: "${FILEBEAT_TIMEZONE:?Define FILEBEAT_TIMEZONE in ${SCRIPT_DIR}/.env (use UTC if unknown)}"

# Ensure no stale container is running
docker rm -f filebeat >/dev/null 2>&1 || true

exec docker run \
  --name=filebeat \
  --user=root \
  --volume="${SCRIPT_DIR}/filebeat.docker.yml:/usr/share/filebeat/filebeat.yml:ro" \
  --volume="${SCRIPT_DIR}/certs:/usr/share/filebeat/certs:ro" \
  --volume="/var/lib/docker/containers:/var/lib/docker/containers:ro" \
  --volume="/var/run/docker.sock:/var/run/docker.sock:ro" \
  --volume="registry:/usr/share/filebeat/data:rw" \
  --volume="${V2CI_BUILD_DIR}:${V2CI_BUILD_DIR}:ro" \
  --env="V2CI_BUILD_DIR=${V2CI_BUILD_DIR}" \
  --env="LOGSTASH_PORT=${LOGSTASH_PORT}" \
  --env="KIBANA_PORT=${KIBANA_PORT}" \
  --env="ES_PORT=${ES_PORT}" \
  --env="FILEBEAT_TIMEZONE=${FILEBEAT_TIMEZONE}" \
  --add-host="v2ci-logstash:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-kibana:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-1:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-2:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-master-3:${ELASTIC_HOST_IP}" \
  --add-host="v2ci-es-hot-1:${ELASTIC_HOST_IP}" \
  docker.elastic.co/beats/filebeat:${STACK_VERSION} filebeat -e --strict.perms=false \
  --path.home /usr/share/filebeat