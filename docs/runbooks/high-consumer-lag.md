# Runbook: High Kafka consumer lag

**Alert:** `KafkaConsumerLagCritical` - `kafka_consumergroup_lag > 10000` for 5m.

## 1. Triage (2 minutes)

```bash
# which group/topic is behind and by how much
curl -s http://kafka-exporter.kafka:9308/metrics | grep kafka_consumergroup_lag{

# consumer pods alive?
kubectl -n apps get pods -l app=consumer
kubectl -n apps logs -l app=consumer --tail=50

# broker health
kubectl -n kafka get pods
kubectl -n kafka get kafkabrokers -n kafka -o yaml | grep -A5 conditions
```

## 2. Common causes → actions

| Cause | Signal | Action |
|---|---|---|
| Consumer crash-looping | `RESTARTS` column > 0 | `kubectl -n apps describe pod <p>` - check Vault agent login, Kafka bootstrap, OTEL endpoint |
| Broker down / leader election | `kafka_brokers < 3` | see [kafka-broker-loss.md](kafka-broker-loss.md) |
| Processing too slow | CPU throttling in `kubectl top pods` | scale consumers: `kubectl -n apps scale deploy/consumer --replicas=3` (or bump resources in `gitops/environments/*/consumer-values.yaml`) |
| Traffic spike (producer rate) | producer logs, `PRODUCE_RATE` | lower rate in values or scale consumers - both through Git |

## 3. Verify recovery

- Alert resolves after lag < 10000 for 5m (Alertmanager → resolved notification).
- `kubectl -n apps logs -l app=consumer` shows `offset committed` lines again.

## 4. Escalation

If lag keeps growing with healthy pods: check mesh connectivity
([mesh-connectivity.md](mesh-connectivity.md)) and Jaeger for slow spans.
