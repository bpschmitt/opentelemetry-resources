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
# Mutation shapes follow docs.newrelic.com/docs/apis/nerdgraph/examples/nerdgraph-scorecards-tutorial.
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

# Comma-separated, single-quoted list for NRQL IN (...), e.g. 'orders-demo','orders-demo-noncompliant'
SERVICES_NRQL_LIST="$(jq -r '.services | map("'"'"'" + . + "'"'"'") | join(",")' "$CFG")"
SCORECARD_NAME="$(jq -r .name "$CFG")"
SCORECARD_DESC="$(jq -r .description "$CFG")"

# Rule NRQL: Scorecard rules are evaluated per entity and must return a 0/1
# `score` faceted by `entityGuid`. Score is 1 when the percent of the entity's
# telemetry that is compliant is >= the rule's threshold. `entity.name IN (...)`
# covers every service instance in `services`, so a compliant and a
# non-compliant instance each get their own faceted row.
rule_nrql() {
  jq -r --argjson i "$1" '.rules[$i] |
    "FROM \(.from) SELECT if(percentage(count(*), WHERE \(.compliant)) >= \(.threshold), 1, 0) AS '"'score'"' WHERE entity.name IN ('"$SERVICES_NRQL_LIST"') AND \(.where) FACET entity.guid AS '"'entityGuid'"' LIMIT MAX SINCE 1 day ago"' "$CFG"
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

# Scorecard/rule scope is the organization.
if $DRY_RUN; then
  ORG_ID="DRY-RUN-ORG-ID"
else
  ORG_ID="$(gql 'query { actor { organization { id } } }' '{}' | jq -r '.data.actor.organization.id // empty')"
  [[ -n "$ORG_ID" ]] || { echo "could not fetch organization id (check API key)" >&2; exit 1; }
fi

RULE_MUTATION='mutation($rule: EntityManagementScorecardRuleEntityCreateInput!) {
  entityManagementCreateScorecardRule(scorecardRuleEntity: $rule) { entity { id } }
}'
SCORECARD_MUTATION='mutation($sc: EntityManagementScorecardEntityCreateInput!) {
  entityManagementCreateScorecard(scorecardEntity: $sc) { entity { id rules { id } } }
}'
ADD_MUTATION='mutation($cid: ID!, $ids: [ID!]!) {
  entityManagementAddCollectionMembers(collectionId: $cid, ids: $ids)
}'

# Create the scorecard first; rules are attached after creation.
echo "== scorecard: $SCORECARD_NAME"
VARS="$(jq -n --arg n "$SCORECARD_NAME" --arg d "$SCORECARD_DESC" --arg o "$ORG_ID" \
  '{sc:{name:$n,description:$d,scope:{type:"ORGANIZATION",id:$o},
    progressLevels:[{id:"BASIC",name:"Basic",description:"Semconv compliance",hexColorCode:"#11845C"}]}}')"
RESP="$(gql "$SCORECARD_MUTATION" "$VARS")"
echo "$RESP" | jq -c .
# Rules are added to the scorecard's rules collection, not the scorecard itself.
SC_ID="$(echo "$RESP" | jq -r '.data.entityManagementCreateScorecard.entity.rules.id // empty')"
if ! $DRY_RUN && [[ -z "$SC_ID" ]]; then echo "scorecard create failed" >&2; exit 1; fi

RULE_IDS=()
COUNT="$(jq '.rules | length' "$CFG")"
for ((i = 0; i < COUNT; i++)); do
  NAME="$(jq -r ".rules[$i].name" "$CFG")"
  echo "== rule: $NAME"
  echo "   NRQL: $(rule_nrql "$i")"
  VARS="$(jq -n --arg n "$NAME" --arg d "$(jq -r ".rules[$i].description" "$CFG")" \
    --arg q "$(rule_nrql "$i")" --arg a "$ACCOUNT_ID" --arg o "$ORG_ID" \
    '{rule:{name:$n,description:$d,enabled:true,progressLevel:"BASIC",runInterval:60,
      nrqlEngine:{accounts:[($a|tonumber)],query:$q},scope:{type:"ORGANIZATION",id:$o}}}')"
  RESP="$(gql "$RULE_MUTATION" "$VARS")"
  echo "$RESP" | jq -c .
  $DRY_RUN || RULE_IDS+=("$(echo "$RESP" | jq -r '.data.entityManagementCreateScorecardRule.entity.id // empty')")
done

echo "== attach rules to scorecard"
IDS_JSON="$(printf '%s\n' "${RULE_IDS[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
VARS="$(jq -n --arg c "${SC_ID:-DRY-RUN}" --argjson r "$IDS_JSON" '{cid:$c,ids:$r}')"
gql "$ADD_MUTATION" "$VARS" | jq -c .
