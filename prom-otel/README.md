# OTel Collector -> Prometheus OTLP receiver -> Grafana

Test stack proving an OpenTelemetry Collector can push metrics straight into
Prometheus's native OTLP receiver (no scrape config, no remote-write
adapter), and that the result is queryable from Grafana.

- Collector's `hostmetrics` receiver (cpu, memory, network, load) generates
  real metric data — no extra load-generator container needed.
- Collector exports via the `otlphttp` exporter to Prometheus's
  `/api/v1/otlp/v1/metrics` endpoint.
- Prometheus has `--web.enable-otlp-receiver` set — this is opt-in, disabled
  by default. See https://prometheus.io/docs/guides/opentelemetry/.
- `otlp.translation_strategy: NoTranslation` — PromQL metric/label names come
  through exactly as OTel names them (dots and all), instead of Prometheus's
  default underscore-escaping + unit/type suffixes. Requires UTF-8 mode,
  which is default-on since Prometheus 3.x (this stack uses `prom/prometheus:latest`,
  currently 3.14.0).
- Grafana comes with the Prometheus datasource pre-provisioned.

## Apply

```
kubectl apply -f namespace.yaml
kubectl apply -f prometheus.yaml -f collector.yaml -f grafana.yaml
```

## Verify

1. Everything's running:
   ```
   kubectl -n prom-otel get pods
   ```
2. Collector is exporting cleanly (no `otlphttp` export errors; the `debug`
   exporter also prints the hostmetrics data points it's sending):
   ```
   kubectl -n prom-otel logs deploy/collector
   ```
3. Prometheus actually ingested the data via OTLP (not just that the
   collector sent something):
   ```
   kubectl -n prom-otel port-forward svc/prometheus 9090:9090
   curl -s 'http://localhost:9090/api/v1/label/__name__/values' | grep system
   ```
   Expect the raw OTel names, e.g. `system.cpu.time`, `system.memory.usage`,
   `system.cpu.load_average.1m` — with `translation_strategy: NoTranslation`
   set, the PromQL name matches the OTel metric name exactly (dots included,
   no underscore-escaping or unit/type suffixes).
4. Query from Grafana:
   ```
   kubectl -n prom-otel port-forward svc/grafana 3000:3000
   ```
   Open http://localhost:3000 (default admin/admin), go to Explore, confirm
   the Prometheus datasource is selected, and query one of the metric names
   found in step 3 (use `{__name__="system.cpu.load_average.1m"}` syntax
   since the name contains dots).

## Cleanup

```
kubectl delete namespace prom-otel
```
