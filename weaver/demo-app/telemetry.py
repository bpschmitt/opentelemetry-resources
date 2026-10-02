"""OTel SDK setup shared by both modes.

Destination is chosen from the environment:
  - OTEL_EXPORTER_OTLP_ENDPOINT set  -> use it as-is (e.g. a weaver live-check listener)
  - else NEW_RELIC_LICENSE_KEY set   -> New Relic OTLP endpoint
  - else                             -> localhost:4317
"""

import os
from dataclasses import dataclass

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from generated.attributes import SERVICE_INSTANCE_ID, SERVICE_NAME
from generated.metrics import ORDERS_CHECKOUT_COUNT

NR_OTLP_ENDPOINT = "https://otlp.nr-data.net:4317"
SCOPE = "orders"


@dataclass
class Telemetry:
    tracer: trace.Tracer
    checkout_counter: metrics.Counter
    logger: object
    _providers: tuple

    def flush_and_shutdown(self) -> None:
        tracer_provider, meter_provider, logger_provider = self._providers
        for provider in (tracer_provider, meter_provider, logger_provider):
            provider.force_flush()
            provider.shutdown()


def _exporter_kwargs() -> dict:
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    license_key = os.environ.get("NEW_RELIC_LICENSE_KEY")
    if endpoint:
        return {}  # SDK reads OTEL_EXPORTER_OTLP_* itself
    if license_key:
        return {"endpoint": NR_OTLP_ENDPOINT, "headers": {"api-key": license_key}}
    return {}


def setup(service_name: str, export_interval_ms: int = 5000) -> Telemetry:
    resource = Resource.create(
        {
            SERVICE_NAME: service_name,
            SERVICE_INSTANCE_ID: os.environ.get("HOSTNAME", "local"),
        }
    )
    kwargs = _exporter_kwargs()

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(**kwargs)))
    trace.set_tracer_provider(tracer_provider)

    meter_provider = MeterProvider(
        resource=resource,
        metric_readers=[
            PeriodicExportingMetricReader(OTLPMetricExporter(**kwargs), export_interval_millis=export_interval_ms)
        ],
    )
    metrics.set_meter_provider(meter_provider)

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(**kwargs)))

    counter = meter_provider.get_meter(SCOPE).create_counter(
        ORDERS_CHECKOUT_COUNT,
        unit="{checkout}",
        description="Number of order checkouts processed.",
    )
    return Telemetry(
        tracer=tracer_provider.get_tracer(SCOPE),
        checkout_counter=counter,
        logger=logger_provider.get_logger(SCOPE),
        _providers=(tracer_provider, meter_provider, logger_provider),
    )
