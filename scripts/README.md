# Scripts

Standalone helper scripts for testing/exercising New Relic OTLP ingest. Each script self-contained, runnable directly.

## Index

| Script | Purpose |
|---|---|
| [send-otlp-custom-event.sh](#send-otlp-custom-eventsh) | Send OTLP log record that transforms into a New Relic custom event on ingest |

---

## send-otlp-custom-event.sh

Sends single OTLP log record to New Relic, designed to transform into custom event on ingest.

### How it works

Log record carrying attribute `newrelic.event.type` stored as CUSTOM EVENT instead of Log. Value of that attribute becomes NRQL event type (`FROM <EventType>`). Every other attribute on log record becomes attribute/column on event.

Docs: https://docs.newrelic.com/docs/opentelemetry/best-practices/opentelemetry-best-practices-logs/#custom-events

The record also sets the top-level `eventName` field per the [OTel Events semantic conventions](https://opentelemetry.io/docs/specs/semconv/general/events/), using the same value as `EVENT_TYPE`. `eventName` and `newrelic.event.type` are independent — `eventName` names the OTel event structure, `newrelic.event.type` is what actually drives New Relic's custom-event transform.

### Usage

```bash
export NEW_RELIC_LICENSE_KEY="your-ingest-license-key"
./send-otlp-custom-event.sh
```

Override defaults:

```bash
EVENT_TYPE=MyCustomEvent NR_REGION=EU ./send-otlp-custom-event.sh
```

### Config (env vars)

| Var | Default | Notes |
|---|---|---|
| `NEW_RELIC_LICENSE_KEY` | *(required)* | Ingest license key |
| `EVENT_TYPE` | `OtelCustomEventTest` | Becomes NRQL `FROM <type>`; also sent as `LogRecord.eventName` |
| `SERVICE_NAME` | `otlp-custom-event-test` | Resource attribute `service.name` |
| `NR_REGION` | `US` | `US` \| `EU` \| `JP` \| `FEDRAMP` — picks OTLP endpoint |
| `OTLP_ENDPOINT` | *(derived from region)* | Override to bypass region lookup |

### Verify

Script prints HTTP response and a run ID. Query in New Relic:

```
FROM <EVENT_TYPE> SELECT * WHERE run.id = '<run-id>' SINCE 10 minutes ago
```

Custom events are typically queryable within ~30-60s.
