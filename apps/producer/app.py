"""
Utravs sample producer.

- produces JSON events to a Kafka topic at a configurable rate
- OpenTelemetry traces: one span per produced message, trace context is
  propagated through Kafka headers so the consumer continues the SAME trace
  (end-to-end tracing requirement)
- structured JSON logs including trace_id/span_id (log <-> trace correlation)
- reads its secret from the Vault agent file (/vault/secrets/...) - the
  secret never exists in Git, Helm values or ConfigMaps
- delivery semantics: acks=all + idempotence + retries => at-least-once
- exposes /healthz for probes
"""

import json
import logging
import os
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from confluent_kafka import Producer
from opentelemetry import trace
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "utravs-kafka-kafka-bootstrap.kafka:9092")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "orders")
KAFKA_ACKS = os.environ.get("KAFKA_ACKS", "all")
KAFKA_RETRIES = int(os.environ.get("KAFKA_RETRIES", "10"))
PRODUCE_RATE = float(os.environ.get("PRODUCE_RATE", "5"))
OTLP_ENDPOINT = os.environ.get(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "http://otel-collector.observability.svc.cluster.local:4317",
)
OTLP_SERVICE = os.environ.get("OTEL_SERVICE_NAME", "producer")
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
    """Injects the active trace ids into every log record (correlation)."""

    def filter(self, record):
        span = trace.get_current_span()
        ctx = span.get_span_context()
        record.trace_id = format(ctx.trace_id, "032x") if ctx.trace_id else "-" * 32
        record.span_id = format(ctx.span_id, "016x") if ctx.span_id else "-" * 16
        return True

for handler in logging.getLogger().handlers:
    handler.addFilter(_TraceFilter())

def read_secret() -> str:
    """Read the token injected by the Vault agent (runtime-only secret)."""
    try:
        with open(SECRET_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRODUCER_TOKEN="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        log.warning("secret file not found (vault agent not injected yet)")
    return "unavailable"

producer = Producer(
    {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "acks": KAFKA_ACKS,
        "retries": int(KAFKA_RETRIES),
        "enable.idempotence": True,
        "linger.ms": 5,
    }
)

def delivery_report(err, msg):
    if err:
        log.error("message delivery failed: %s", err)
    else:
        log.info(
            "message delivered topic=%s partition=%s offset=%s",
            msg.topic(), msg.partition(), msg.offset(),
        )

def produce_loop(stop_event: threading.Event):
    counter = 0
    interval = 1.0 / max(PRODUCE_RATE, 0.1)
    while not stop_event.is_set():
        counter += 1
        with tracer.start_as_current_span("produce-order") as span:

            msg_id = str(uuid.uuid4())
            payload = {
                "id": msg_id,
                "ts": time.time(),
                "event": "order.created",
                "data": {"item": f"sku-{counter % 100}", "qty": (counter % 5) + 1},
            }

            carrier = {}
            _propagator.inject(carrier)
            headers = [(k, v.encode("utf-8")) for k, v in carrier.items()]

            span.set_attribute("messaging.system", "kafka")
            span.set_attribute("messaging.destination", KAFKA_TOPIC)
            span.set_attribute("messaging.message.id", msg_id)

            producer.produce(
                KAFKA_TOPIC,
                partition=counter % 3,
                key=str(counter % 3).encode("utf-8"),
                value=json.dumps(payload).encode("utf-8"),
                headers=headers,
                on_delivery=delivery_report,
            )
            producer.flush(5)
            log.info("produced event id=%s", msg_id)
        stop_event.wait(interval)

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
        "producer starting topic=%s bootstrap=%s rate=%s/s secret_loaded=%s",
        KAFKA_TOPIC, KAFKA_BOOTSTRAP, PRODUCE_RATE, token != "unavailable",
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

    threading.Thread(target=produce_loop, args=(stop_event,), daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", APP_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    while not stop_event.is_set():
        time.sleep(0.5)
    server.shutdown()
    producer.flush(10)
    log.info("producer stopped gracefully")

if __name__ == "__main__":
    main()
