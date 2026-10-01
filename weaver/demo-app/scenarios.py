"""Compliant and non-compliant order emitters.

Each violation maps to one scorecard rule (see scorecard/scorecard.json).
"""

import random
import time
import uuid

from opentelemetry._logs import SeverityNumber
from opentelemetry.trace import Status, StatusCode

from telemetry import Telemetry

CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CAD"]
PAYMENT_METHODS = ["credit_card", "paypal", "gift_card"]
ERROR_TYPES = ["card_declined", "out_of_stock", "timeout"]

VIOLATIONS = [
    "total_as_string",       # order.total: string instead of double
    "missing_order_id",      # required order.id absent
    "stray_attribute",       # undefined `orderId`
    "invalid_currency",      # lowercase / non-ISO code
    "unknown_span_name",     # `order.checkout` instead of `orders.checkout`
    "bad_payment_method",    # value outside the registry enum
    "metric_currency_int",   # metric order.currency as int
]


def _order() -> dict:
    items = random.randint(1, 8)
    return {
        "id": f"ord_{uuid.uuid4().hex[:6]}",
        "total": round(random.uniform(5, 400), 2),
        "currency": random.choice(CURRENCIES),
        "payment_method": random.choice(PAYMENT_METHODS),
        "item_count": items,
    }


def emit_order(t: Telemetry, violation: str | None = None, simulate_work: bool = True) -> None:
    o = _order()
    span_name = "orders.checkout"
    attrs = {
        "order.id": o["id"],
        "order.total": o["total"],
        "order.currency": o["currency"],
        "order.payment_method": o["payment_method"],
        "order.item_count": o["item_count"],
    }
    metric_currency = o["currency"]

    if violation == "total_as_string":
        attrs["order.total"] = str(o["total"])
    elif violation == "missing_order_id":
        del attrs["order.id"]
    elif violation == "stray_attribute":
        attrs["orderId"] = o["id"]
    elif violation == "invalid_currency":
        attrs["order.currency"] = o["currency"].lower()
        metric_currency = o["currency"].lower()
    elif violation == "unknown_span_name":
        span_name = "order.checkout"
    elif violation == "bad_payment_method":
        attrs["order.payment_method"] = "bitcoin"
    elif violation == "metric_currency_int":
        metric_currency = 840

    failed = random.random() < 0.05
    with t.tracer.start_as_current_span(span_name, attributes=attrs) as span:
        if simulate_work:
            time.sleep(random.uniform(0.02, 0.25))
        if failed:
            err = random.choice(ERROR_TYPES)
            span.set_status(Status(StatusCode.ERROR, err))
            log_attrs = {"error.type": err}
            if violation != "missing_order_id":
                log_attrs["order.id"] = o["id"]
            t.logger.emit(
                event_name="orders.checkout.failed",
                severity_number=SeverityNumber.ERROR,
                severity_text="ERROR",
                body=f"checkout failed: {err}",
                attributes=log_attrs,
            )

    t.checkout_counter.add(1, {"order.currency": metric_currency})
