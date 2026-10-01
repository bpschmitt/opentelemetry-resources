# Weaver demo app + New Relic scorecard

One app, two modes, built on the [registry](../model/orders.yaml):

| Mode | What it does | Where it sends |
|---|---|---|
| `demo` | Runs forever, emitting realistic `orders.checkout` spans, `orders.checkout.count` metrics and `orders.checkout.failed` log events. `NONCOMPLIANT_RATIO` of orders carry one registry violation. | New Relic (if `NEW_RELIC_LICENSE_KEY` is set), or `OTEL_EXPORTER_OTLP_ENDPOINT` |
| `live-check` | Sends a tiny sample (spans, metric points and a log, compliant and non-compliant) and exits. | `weaver registry live-check` on `localhost:4317` |

## Violations injected in demo mode

| Violation | Registry rule broken | Scorecard rule |
|---|---|---|
| `total_as_string` | `order.total` must be `double` | order.total is numeric |
| `missing_order_id` | `order.id` required | required `order.id` |
| `stray_attribute` | `orderId` not in registry | no attributes outside the registry |
| `invalid_currency` | lowercase, not ISO 4217 | order.currency is an ISO 4217 code |
| `unknown_span_name` | `order.checkout` not a registry span | only registry span names |
| `bad_payment_method` | value outside `order.payment_method` enum | payment method enum |
| `metric_currency_int` | metric `order.currency` must be a string | metric currency |

Weaver live-check flags all of these. Type, missing-attribute and unknown-attribute cases work out of the box. The value-level ones need two additions in this repo:

- `order.currency` and `order.payment_method` are **enums** in [model/orders.yaml](../model/orders.yaml). Without members, a registry can't say what a valid value is, so `jpy` passes as "just a string".
- [policies/orders.rego](../policies/orders.rego) escalates undocumented enum values from weaver's built-in `information` level to `violation`, and flags span names that aren't in [policies/data/orders.json](../policies/data/orders.json). `.weaver.toml` loads them automatically when weaver is run from `weaver/`.

The scorecard then measures the same rules continuously on production-shaped telemetry, instead of only on a sample.

## Config

| Variable | Default | Purpose |
|---|---|---|
| `NEW_RELIC_LICENSE_KEY` | | Ingest key. Sends to `otlp.nr-data.net:4317` when no endpoint override is set. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | | Overrides the destination (e.g. a live-check listener). |
| `OTEL_SERVICE_NAME` | `orders-demo` | Service name (scorecard is scoped to `orders-demo`). |
| `ORDERS_PER_SEC` | `2` | Average order rate. |
| `NONCOMPLIANT_RATIO` | `0.15` | Share of orders with a violation. |

## Run

Install deps (from `weaver/`): `.venv/bin/pip install -r demo-app/requirements.txt`

**Live-check mode** (run from `weaver/` so `.weaver.toml` resolves the registry):

```
weaver registry live-check --inactivity-timeout 30
python demo-app/app.py --mode live-check          # add --compliant-only to skip violations
```

**Demo mode, local:**

```
export NEW_RELIC_LICENSE_KEY=...
python demo-app/app.py --mode demo
```

**Docker:**

```
docker build -t weaver-orders-demo:latest demo-app
docker run --rm -e NEW_RELIC_LICENSE_KEY weaver-orders-demo:latest
```

**Kubernetes:**

```
kubectl create secret generic newrelic-license --from-literal=license-key="$NEW_RELIC_LICENSE_KEY"
kubectl apply -f demo-app/k8s/demo-app.yaml
```

## Scorecard

[scorecard/scorecard.json](./scorecard/scorecard.json) defines seven rules; each computes the percentage of `orders-demo` telemetry that conforms to the registry and passes at its threshold. Example:

```
FROM Span SELECT percentage(count(*), WHERE `order.total` >= 0) AS compliance
WHERE entity.name = 'orders-demo' AND name = 'orders.checkout'
```

(A string-typed `order.total` fails the numeric comparison, so it counts as non-compliant.)

```
export NEW_RELIC_API_KEY=NRAK-... NEW_RELIC_ACCOUNT_ID=1234567
scorecard/apply.sh --dry-run    # print NRQL + payloads
scorecard/apply.sh
```

With the default 15% violation ratio, spread over seven violation types, most rules land around 97-98% and the strict 99% ones fail, giving a mixed scorecard. Raise `NONCOMPLIANT_RATIO` to push more rules red.

**Unverified:** the NerdGraph `entityManagement*Scorecard*` mutation shapes in `apply.sh` and the exact NRQL pass semantics were written without access to a New Relic account. Run each NRQL in the query builder first, and check the mutations in the NerdGraph explorer if a call is rejected. The NRQL type check for `order.total` relies on numeric comparison excluding string values; confirm that too.
