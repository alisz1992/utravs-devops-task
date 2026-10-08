# Runbook: Secret rotation without downtime

Manual runbook for the rotation demo (`scripts/rotate-secret.sh` automates
steps 1–3).

## 1. Rotate the value in Vault

```bash
./scripts/rotate-secret.sh producer        # kv/data/producer  (prod)
./scripts/rotate-secret.sh producer dev    # kv/data/producer-dev
```

The script writes a new token and then polls the Vault agent file
`/vault/secrets/kafka-creds` inside a **running** pod until the new value
appears (up to 10 minutes).

## 2. Watch the application pick it up

The apps re-read `SECRET_FILE` periodically and log:

```
{"...","msg":"secret value changed - new token detected"}
```

No pod restart is involved - the sidecar re-renders the file.

## 3. Fallback if the agent does not re-render in time

The deployment uses `RollingUpdate` with `maxUnavailable: 0`, so a restart
never drops below the desired replica count:

```bash
kubectl -n apps rollout restart deploy/producer
kubectl -n apps rollout status deploy/producer
```

This is still "without significant downtime" (brief overlap of old/new pod),
and the runbook records which path was used in the reliability report.

## 4. Rules

- Never copy the new value into Git, Helm values or ConfigMaps.
- After rotation, confirm the old value stops working:
  `kubectl -n vault exec vault-0 -c vault -- vault kv get -field=token kv/data/producer`
