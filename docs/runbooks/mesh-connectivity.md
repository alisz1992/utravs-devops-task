# Runbook: Mesh connectivity problems / mTLS issues

**Alerts:** `IstioMeshHighErrorRate`, `IstiodDown`,
`IstioPodWithoutSidecarTraffic`.

## 1. Triage

```bash
# control plane alive?
kubectl -n istio-system get pods
kubectl -n istio-system logs deploy/istiod --tail=30

# policy still STRICT? (must never be changed to PERMISSIVE as a fix)
kubectl get peerauthentications -A

# sidecars present on all injected namespaces?
kubectl -n apps get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'

# per-workload proxy status
kubectl -n apps exec deploy/producer -c istio-proxy -- pilot-agent proxy-status
```

## 2. Common causes → actions

| Cause | Action |
|---|---|
| istiod down | `kubectl -n istio-system rollout restart deploy/istiod`; check pilot logs for cert/signing errors |
| Namespace missing injection label | label it in `gitops/components/mesh/mesh-config.yaml` (never by hand) and let ArgoCD sync, then rollout the deployment |
| Old pods without sidecar after label change | `kubectl -n <ns> rollout restart deploy/<name>` |
| New mTLS bypass detection alert | investigate which source workload sends plaintext - fix the client, **do not** relax PeerAuthentication |

## 3. Verify

- 5xx rate returns below 5% (Grafana "Mesh" dashboard).
- `IstioPodWithoutSidecarTraffic` stays silent.
- Jaeger still shows end-to-end traces for producer → consumer.
