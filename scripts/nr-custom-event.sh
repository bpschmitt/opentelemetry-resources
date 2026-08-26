#!/usr/bin/env bash
#
# send-otlp-custom-event.sh
#
# Sends a single OTLP log record to New Relic that is designed to be
# transformed into a custom event on ingest.
#
# How the transform works (per New Relic OpenTelemetry logs best practices):
#   A log record that carries the attribute `newrelic.event.type` is stored as
#   a CUSTOM EVENT instead of a Log. The VALUE of that attribute becomes the
#   NRQL event type (the "table" you query with FROM <EventType>). Every other
#   attribute on the log record becomes an attribute/column on that event.
#   Docs: https://docs.newrelic.com/docs/opentelemetry/best-practices/opentelemetry-best-practices-logs/#custom-events
#
# Usage:
#   export NEW_RELIC_LICENSE_KEY="your-ingest-license-key"
#   ./send-otlp-custom-event.sh
#
#   # override defaults:
#   EVENT_TYPE=MyCustomEvent NR_REGION=EU ./send-otlp-custom-event.sh
#
set -euo pipefail

# ----- config (override via environment) -------------------------------------
: "${NEW_RELIC_LICENSE_KEY:?Set NEW_RELIC_LICENSE_KEY to your New Relic ingest license key}"

EVENT_TYPE="${EVENT_TYPE:-OtelCustomEventTest}"   # becomes the NRQL FROM <type>
SERVICE_NAME="${SERVICE_NAME:-otlp-custom-event-test}"
NR_REGION="${NR_REGION:-US}"                       # US | EU | JP | FEDRAMP

# Resolve the OTLP HTTP endpoint for the region (unless OTLP_ENDPOINT is set).
case "${OTLP_ENDPOINT:-}" in
  "")
    case "$(printf '%s' "$NR_REGION" | tr '[:lower:]' '[:upper:]')" in
      US)      OTLP_ENDPOINT="https://otlp.nr-data.net" ;;
      EU)      OTLP_ENDPOINT="https://otlp.eu01.nr-data.net" ;;
      JP)      OTLP_ENDPOINT="https://otlp.jp.nr-data.net" ;;
      FEDRAMP) OTLP_ENDPOINT="https://gov-otlp.nr-data.net" ;;
      *) echo "Unknown NR_REGION '$NR_REGION' (use US, EU, JP, or FEDRAMP)" >&2; exit 1 ;;
    esac
    ;;
esac
LOGS_URL="${OTLP_ENDPOINT%/}/v1/logs"

# ----- portable nanosecond timestamp -----------------------------------------
# GNU date supports %N; BSD/macOS date does not, so fall back to seconds * 1e9.
now_ns() {
  local n
  n="$(date +%s%N 2>/dev/null || true)"
  if [[ -z "$n" || "$n" == *N* || ${#n} -lt 19 ]]; then
    n="$(date +%s)000000000"
  fi
  printf '%s' "$n"
}
TS_NANO="$(now_ns)"

# A unique id per run so you can find this exact event in NRQL afterward.
RUN_ID="run-$(date +%s)-${RANDOM}"

# ----- OTLP/JSON logs payload -------------------------------------------------
# The `newrelic.event.type` attribute is what triggers the custom-event transform.
read -r -d '' PAYLOAD <<JSON || true
{
  "resourceLogs": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "${SERVICE_NAME}" } }
        ]
      },
      "scopeLogs": [
        {
          "scope": { "name": "nr-custom-event.sh" },
          "logRecords": [
            {
              "timeUnixNano": "${TS_NANO}",
              "observedTimeUnixNano": "${TS_NANO}",
              "severityNumber": 9,
              "severityText": "INFO",
              "body": { "stringValue": "custom event test emitted from send-otlp-custom-event.sh" },
              "attributes": [
                { "key": "newrelic.event.type", "value": { "stringValue": "${EVENT_TYPE}" } },
                { "key": "run.id",     "value": { "stringValue": "${RUN_ID}" } },
                { "key": "environment","value": { "stringValue": "test" } },
                { "key": "user.id",    "value": { "stringValue": "12345" } },
                { "key": "order.total","value": { "doubleValue": 42.50 } },
                { "key": "items.count","value": { "intValue": "3" } },
                { "key": "is.priority","value": { "boolValue": true } }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON

# ----- send -------------------------------------------------------------------
echo "POST  ${LOGS_URL}"
echo "event.type : ${EVENT_TYPE}"
echo "run.id     : ${RUN_ID}"
echo

HTTP_CODE="$(
  curl -sS -o /tmp/nr_otlp_resp.$$ -w '%{http_code}' \
    -X POST "${LOGS_URL}" \
    -H "Content-Type: application/json" \
    -H "api-key: ${NEW_RELIC_LICENSE_KEY}" \
    --data-binary "${PAYLOAD}"
)"

echo "HTTP ${HTTP_CODE}"
echo "Response body:"
cat "/tmp/nr_otlp_resp.$$" 2>/dev/null || true
echo
rm -f "/tmp/nr_otlp_resp.$$"

if [[ "$HTTP_CODE" =~ ^20[0-9]$ ]]; then
  cat <<EOF

Accepted. Custom events are typically queryable within ~30-60s.
Verify in New Relic (query builder) with:

  FROM ${EVENT_TYPE} SELECT * WHERE run.id = '${RUN_ID}' SINCE 10 minutes ago
EOF
else
  echo "Ingest did not return 2xx. Check the license key, region, and endpoint." >&2
  exit 1
fi