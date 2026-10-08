# Runbook: Vault sealed or unavailable

**Alerts:** `VaultSealedCritical` (`vault_core_unsealed == 0`), `VaultDown`.

## 1. Triage

```bash
# which node is sealed
for p in vault-0 vault-1 vault-2; do
  echo -n "$p: "
  kubectl -n vault exec $p -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 \
    vault status -format=json | grep -E '"sealed"|"n"'
done

kubectl -n vault get pods
kubectl -n vault logs <sealed-pod> -c vault --tail=50
```

## 2. Actions

**A node is sealed (raft still has quorum):**

```bash
# use ONE key per share, from vault-init.json (operator host, chmod 600)
kubectl -n vault exec vault-X -c vault -- env VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal <key-1>
# repeat with key-2 and key-3 until "Sealed: false"
```

**All nodes sealed / Vault pods down:** restore from `vault-init.json`
(unseal keys + root token). If the file is lost, the data is
** unrecoverable ** in this lab setup - in production auto-unseal avoids this
(see docs/tradeoffs.md).

**Active node lost:** no action needed - a standby takes over automatically
(prove it with `scripts/test-vault-failover.sh`).

## 3. Impact statement

While sealed: Vault Agent sidecars retry login; running pods keep the last
rendered secret file until its TTL; new pods stay in
`CreateContainerConfigError`-like state. Kafka and the mesh keep working -
only secret reads are affected.

## 4. Verify

```bash
kubectl -n apps get pods          # no new restarts
kubectl -n apps logs -l app=producer --tail=20 | grep secret
./scripts/rotate-secret.sh producer   # optional end-to-end check
```
