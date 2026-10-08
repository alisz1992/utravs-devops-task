"""
Utravs sample consumer.

- consumes JSON events from a Kafka topic
- delivery semantics: at-least-once - offsets are committed ONLY after the
  message was processed (enable.auto.commit=false + manual commit)
- idempotent processing: already-seen message ids are skipped, which makes
  redelivered (duplicate) messages harmless
- OpenTelemetry: continues the trace started by the producer via Kafka
  headers (end-to-end trace in Jaeger)
- structured JSON logs with trace_id/span_id for log <-> trace correlation
- reads its secret from the Vault agent file (runtime-only secret)
- exposes /healthz for probes
"""

import json
import logging
import os
import signal
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from confluent_kafka import Consumer, KafkaException
from opentelemetry import trace
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "utravs-kafka-kafka-bootstrap.kafka:9092")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "orders")
CONSUMER_GROUP = os.environ.get("CONSUMER_GROUP", "orders-consumers")
AUTO_OFFSET_RESET = os.environ.get("AUTO_OFFSET_RESET", "earliest")
OTLP_ENDPOINT = os.environ.get(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "http://otel-collector.observability.svc.cluster.local:4317",
)
OTLP_SERVICE = os.environ.get("OTEL_SERVICE_NAME", "consumer")
SECRET_FILE = os.environ.get("SECRET_FILE", "/vault/secrets/kafka-creds")
APP_PORT = int(os.environ.get("APP_PORT", "8080"))

resource = Resource.create({"service.name": OTLP_SERVICE})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(OTLP_SERVICE)

_propagator = TraceContextTextMapPropagator()

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"%(name)s",'
           '"trace_id":"%(trace_id)s","span_id":"%(span_id)s","msg":"%(message)s"}',
)
log = logging.getLogger(OTLP_SERVICE)

class _TraceFilter(logging.Filter):
    def filter(self, record):
        span = trace.get_current_span()
        ctx = span.get_span_context()
        record.trace_id = format(ctx.trace_id, "032x") if ctx.trace_id else "-" * 32
        record.span_id = format(ctx.span_id, "016x") if ctx.span_id else "-" * 16
        return True

for handler in logging.getLogger().handlers:
    handler.addFilter(_TraceFilter())

def read_secret() -> str:
    try:
        with open(SECRET_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("CONSUMER_TOKEN="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        log.warning("secret file not found (vault agent not injected yet)")
    return "unavailable"

consumer = Consumer(
    {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": CONSUMER_GROUP,
        "auto.offset.reset": AUTO_OFFSET_RESET,

        "enable.auto.commit": False,
        "enable.auto.offset.store": False,
    }
)

_SEEN_MAX = 100_000
_seen_ids: set = set()
_seen_order: deque = deque()
_seen_lock = threading.Lock()

def _remember(mid) -> bool:
    """True when this id has NOT been seen before (caller should process)."""
    with _seen_lock:
        if mid in _seen_ids:
            return False
        _seen_ids.add(mid)
        _seen_order.append(mid)
        while len(_seen_order) > _SEEN_MAX:
            _seen_ids.discard(_seen_order.popleft())
        return True

def process(payload: dict) -> None:
    """Business logic placeholder - must stay idempotent."""
    mid = payload.get("id")
    if not _remember(mid):
        log.info("duplicate message id=%s ignored (idempotent)", mid)
        return
    log.info("processed event id=%s item=%s", mid, payload.get("data", {}).get("item"))

def consume_loop(stop_event: threading.Event):
    consumer.subscribe([KAFKA_TOPIC])
    log.info("consumer subscribed topic=%s group=%s", KAFKA_TOPIC, CONSUMER_GROUP)
    while not stop_event.is_set():
        msg = consumer.poll(timeout=1.0)
        if msg is None:
            continue
        if msg.error():
            log.error("kafka error: %s", msg.error())
            continue

        carrier = {k: v.decode("utf-8", errors="ignore") for k, v in (msg.headers() or [])}
        ctx = _propagator.extract(carrier)
        with tracer.start_as_current_span("consume-order", context=ctx) as span:
            span.set_attribute("messaging.system", "kafka")
            span.set_attribute("messaging.source", f"{msg.topic()}[{msg.partition()}]")
            span.set_attribute("messaging.offset", msg.offset())
            try:
                payload = json.loads(msg.value().decode("utf-8"))
                process(payload)

                consumer.commit(message=msg, asynchronous=False)
                log.info(
                    "offset committed topic=%s partition=%s offset=%s",
                    msg.topic(), msg.partition(), msg.offset(),
                )
            except KafkaException as exc:
                log.error("processing failed: %s", exc)
            except Exception as exc:
                log.error("unexpected error: %s", exc)

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/healthz"):
            body = json.dumps({"status": "ok", "service": OTLP_SERVICE}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):
        pass

def main():
    stop_event = threading.Event()

    def _handle_signal(*_args):
        stop_event.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    token = read_secret()
    log.info(
        "consumer starting group=%s topic=%s secret_loaded=%s",
        CONSUMER_GROUP, KAFKA_TOPIC, token != "unavailable",
    )

    def _watch_secret():
        """Re-read the injected file so a rotation is visible at runtime."""
        last = token
        while not stop_event.is_set():
            time.sleep(15)
            current = read_secret()
            if current != last:
                log.info("secret value changed - new token detected")
                last = current

    threading.Thread(target=_watch_secret, daemon=True).start()

    threading.Thread(target=consume_loop, args=(stop_event,), daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", APP_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    while not stop_event.is_set():
        time.sleep(0.5)
    server.shutdown()
    consumer.close()
    log.info("consumer stopped gracefully")

if __name__ == "__main__":
    main()
