# Runbook: Kafka broker lost

**Alert:** `KafkaBrokerDown` - `kafka_brokers < 3` for 3m.

## 1. Triage

```bash
kubectl -n kafka get pods -o wide
kubectl -n kafka get kafkabrokers -o yaml | grep -A10 conditions
kubectl -n kafka logs <bad-pod> -c kafka --tail=50
kubectl -n kafka get pvc   # storage problems?
```

## 2. Actions

| Situation | Action |
|---|---|
| Pod CrashLoopBackOff | read container logs; check PVC binding and JVM heap (`OutOfMemoryError`) |
| Node pressure | `kubectl describe node <n>` - disk/memory; free space or drain |
| Intentional full restart | `kubectl -n kafka rollout restart kafka/utravs-kafka` (Strimzi rolls one broker at a time) |
| Data loss after disk failure | Strimzi rebuilds the replica from peers; check `status.replicas` before resuming traffic |

Keep `min.insync.replicas=2` and `replication.factor=3` - with one broker
down writes still succeed (`acks=all` needs 2 in-sync replicas).

## 3. Verify

- `kafka_brokers` metric back to 3.
- Consumer lag returning to normal ([high-consumer-lag.md](high-consumer-lag.md)).
- Producer logs show `message delivered` again.
