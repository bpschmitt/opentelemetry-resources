"""Weaver demo app: registry-conformant telemetry with a controlled share of violations.

Modes:
  demo        Run forever, emitting realistic orders. NONCOMPLIANT_RATIO of them
              carry one registry violation. Exports to New Relic (or OTLP env).
  live-check  Send a tiny sample (1 span, 1 metric, 1 log — one compliant and
              one non-compliant set) to a running `weaver registry live-check`.
"""

import argparse
import logging
import os
import random
import signal
import time

import scenarios
import telemetry
from generated.attributes import ORDER_ID
from generated.events import ORDERS_CHECKOUT_FAILED

log = logging.getLogger("orders-demo")


def run_demo() -> None:
    rate = float(os.environ.get("ORDERS_PER_SEC", "2"))
    ratio = float(os.environ.get("NONCOMPLIANT_RATIO", "0.15"))
    t = telemetry.setup(os.environ.get("OTEL_SERVICE_NAME", "orders-demo"))

    stop = False

    def _stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    log.info("demo mode: %.1f orders/s, %.0f%% non-compliant", rate, ratio * 100)
    sent = 0
    while not stop:
        violation = random.choice(scenarios.VIOLATIONS) if random.random() < ratio else None
        scenarios.emit_order(t, violation)
        sent += 1
        if sent % 100 == 0:
            log.info("emitted %d orders", sent)
        time.sleep(random.expovariate(rate))
    t.flush_and_shutdown()


def run_live_check(compliant_only: bool) -> None:
    os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
    os.environ.setdefault("OTEL_EXPORTER_OTLP_INSECURE", "true")
    t = telemetry.setup("orders-demo", export_interval_ms=500)

    log.info("sending compliant sample (span + metric)")
    scenarios.emit_order(t, None, simulate_work=False)
    if not compliant_only:
        log.info("sending non-compliant sample: order.total as string, order.currency as int on metric")
        scenarios.emit_order(t, "total_as_string", simulate_work=False)
        scenarios.emit_order(t, "metric_currency_int", simulate_work=False)
        # Remaining violations. Value-level ones (enum values, span names) rely on the
        # registry enums plus the Rego policies in weaver/policies, loaded via .weaver.toml.
        for violation in (
            "missing_order_id",
            "stray_attribute",
            "invalid_currency",
            "bad_payment_method",
            "unknown_span_name",
        ):
            log.info("sending non-compliant sample: %s", violation)
            scenarios.emit_order(t, violation, simulate_work=False)
    t.logger.emit(
        event_name=ORDERS_CHECKOUT_FAILED,
        body="sample failure",
        attributes={ORDER_ID: "ord_sample", "error.type": "timeout"},
    )
    t.flush_and_shutdown()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["demo", "live-check"], default=os.environ.get("MODE", "demo"))
    p.add_argument("--compliant-only", action="store_true", help="live-check mode: skip the violating samples")
    args = p.parse_args()
    if args.mode == "demo":
        run_demo()
    else:
        run_live_check(args.compliant_only)


if __name__ == "__main__":
    main()
