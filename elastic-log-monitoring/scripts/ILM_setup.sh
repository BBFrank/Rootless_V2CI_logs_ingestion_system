#!/bin/bash
set -euo pipefail

: "${ES_PORT:?Set ES_PORT in environment}"
ES_URL="https://v2ci-es-master-1:${ES_PORT}"
CA_CERT="config/certs/ca/ca.crt"

if [[ -z "${ELASTIC_PASSWORD:-}" ]]; then
  echo "ELASTIC_PASSWORD not set"
  exit 1
fi

echo "[ILM] Creating/updating policy compiler-logs-ilm"
cat >/tmp/compiler-logs-ilm.json <<'EOF'
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_age": "1d",
            "max_primary_shard_size": "1gb"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
EOF
curl -s -o /dev/null -u "elastic:${ELASTIC_PASSWORD}" --cacert "${CA_CERT}" \
  -H "Content-Type: application/json" -X PUT \
  "${ES_URL}/_ilm/policy/compiler-logs-ilm" \
  -d @/tmp/compiler-logs-ilm.json
echo "[ILM] Policy applied"

echo "[ILM] Creating/updating index template logs-compiler-default-template"
cat >/tmp/logs-compiler-default-template.json <<'EOF'
{
  "index_patterns": [
    "logs-compiler-*",
    ".ds-logs-compiler-*"
  ],
  "composed_of": [
    "logs@mappings",
    "ecs@mappings"
  ],
  "data_stream": {},
  "priority": 500,
  "template": {
    "settings": {
      "index.lifecycle.name": "compiler-logs-ilm",
      "index.number_of_shards": 1,
      "index.number_of_replicas": 0,
      "index.codec": "best_compression"
    },
    "mappings": {
      "dynamic": true
    }
  }
}
EOF
curl -s -o /dev/null -u "elastic:${ELASTIC_PASSWORD}" --cacert "${CA_CERT}" \
  -H "Content-Type: application/json" -X PUT \
  "${ES_URL}/_index_template/logs-compiler-default-template" \
  -d @/tmp/logs-compiler-default-template.json
echo "[ILM] Index template applied"

echo "[ILM] Completed"
