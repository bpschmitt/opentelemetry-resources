#!/usr/bin/env bash
#
# Creates the semconv-compliance scorecard rules in New Relic from scorecard.json.
#
#   export NEW_RELIC_API_KEY="NRAK-..."        # user API key
#   export NEW_RELIC_ACCOUNT_ID="1234567"
#   export NEW_RELIC_REGION="US"               # or EU (default US)
#   ./apply.sh            # create rules
#   ./apply.sh --dry-run  # print each rule's NRQL and the GraphQL payload only
#
# NOTE: the entityManagement*Scorecard* mutation shapes below have not been
# verified against the live NerdGraph schema. Check them in the NerdGraph
# explorer (api.newrelic.com/graphiql) if a call is rejected.
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/scorecard.json"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

if ! $DRY_RUN; then
  : "${NEW_RELIC_API_KEY:?NEW_RELIC_API_KEY is required}"
  : "${NEW_RELIC_ACCOUNT_ID:?NEW_RELIC_ACCOUNT_ID is required}"
fi
ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID:-0}"
ENDPOINT="https://api.newrelic.com/graphql"
[[ "${NEW_RELIC_REGION:-US}" == "EU" ]] && ENDPOINT="https://api.eu.newrelic.com/graphql"

SERVICE="$(jq -r .service "$CFG")"
SCORECARD_NAME="$(jq -r .name "$CFG")"
SCORECARD_DESC="$(jq -r .description "$CFG")"

# Rule NRQL: percent of the service's telemetry that is compliant, restricted
# to the entity being scored. Passes when the result is >= threshold.
rule_nrql() {
  jq -r --argjson i "$1" '.rules[$i] |
    "FROM \(.from) SELECT percentage(count(*), WHERE \(.compliant)) AS compliance WHERE entity.name = '"'$SERVICE'"' AND \(.where)"' "$CFG"
}

gql() {
  local query="$1" variables="$2"
  if $DRY_RUN; then
    jq -n --arg q "$query" --argjson v "$variables" '{query:$q,variables:$v}'
    return
  fi
  curl -sS "$ENDPOINT" -H "Content-Type: application/json" -H "API-Key: $NEW_RELIC_API_KEY" \
    -d "$(jq -n --arg q "$query" --argjson v "$variables" '{query:$q,variables:$v}')"
}

RULE_MUTATION='mutation($rule: EntityManagementScorecardRuleEntityCreateInput!) {
  entityManagementCreateScorecardRule(scorecardRuleEntity: $rule) { entity { id } }
}'
SCORECARD_MUTATION='mutation($sc: EntityManagementScorecardEntityCreateInput!) {
  entityManagementCreateScorecard(scorecardEntity: $sc) { entity { id } }
}'

RULE_IDS=()
COUNT="$(jq '.rules | length' "$CFG")"
for ((i = 0; i < COUNT; i++)); do
  NAME="$(jq -r ".rules[$i].name" "$CFG")"
  echo "== rule: $NAME"
  echo "   NRQL: $(rule_nrql "$i")"
  VARS="$(jq -n --arg n "$NAME" --arg d "$(jq -r ".rules[$i].description" "$CFG")" \
    --arg q "$(rule_nrql "$i")" --argjson t "$(jq ".rules[$i].threshold" "$CFG")" --arg a "$ACCOUNT_ID" \
    '{rule:{name:$n,description:$d,enabled:true,nrqlEngine:{accounts:[($a|tonumber)],query:$q}, threshold:$t}}')"
  RESP="$(gql "$RULE_MUTATION" "$VARS")"
  echo "$RESP" | jq -c .
  $DRY_RUN || RULE_IDS+=("$(echo "$RESP" | jq -r '.data.entityManagementCreateScorecardRule.entity.id')")
done

echo "== scorecard: $SCORECARD_NAME"
RULES_JSON="$(printf '%s\n' "${RULE_IDS[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
VARS="$(jq -n --arg n "$SCORECARD_NAME" --arg d "$SCORECARD_DESC" --argjson r "$RULES_JSON" \
  '{sc:{name:$n,description:$d,rules:($r|map({id:.}))}}')"
gql "$SCORECARD_MUTATION" "$VARS" | jq -c .
