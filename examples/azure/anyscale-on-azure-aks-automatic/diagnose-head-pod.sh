#!/usr/bin/env bash
# Capture WHY the Anyscale head pod won't schedule on AKS.
# Run this, THEN start the workspace in the Anyscale UI. It waits for the
# Ray head pod to appear, then dumps the scheduling decision + autoscaler reason.
set -uo pipefail

# Write captured logs to a gitignored diagnostics/ folder next to this script.
OUT="$(cd "$(dirname "$0")" && pwd)/diagnostics"
mkdir -p "$OUT"
echo "Writing diagnostics to: $OUT"

echo "==> Waiting for a Ray/Anyscale workload pod to appear (start the workspace now)..."
POD=""; NS=""
for i in $(seq 1 240); do   # up to ~20 min
  read -r NS POD <<<"$(kubectl get pods -A -o jsonpath='{range .items[?(@.metadata.labels.ray\.io/node-type)]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
  if [ -z "$POD" ]; then
    # fall back: any pending pod outside system namespaces
    read -r NS POD <<<"$(kubectl get pods -A --field-selector status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -viE '^(kube-system|aks-istio-system|app-routing-system|gatekeeper-system|anyscale-operator) ' | head -1)"
  fi
  [ -n "$POD" ] && break
  sleep 5
done

if [ -z "$POD" ]; then
  echo "No workload pod found. Capturing operator logs + cluster events instead."
  kubectl logs -n anyscale-operator -l app.kubernetes.io/name=anyscale-operator --tail=200 --all-containers >"$OUT/operator_logs.log" 2>&1
  kubectl get events -A --sort-by=.lastTimestamp | tail -60 >"$OUT/events.log" 2>&1
  echo "Saved operator_logs.log + events.log"
  exit 0
fi

echo "==> Found pod: $NS/$POD"
kubectl describe pod -n "$NS" "$POD"            >"$OUT/head_pod_describe.log" 2>&1
kubectl get pod -n "$NS" "$POD" -o yaml         >"$OUT/head_pod.yaml"         2>&1

echo "==> Scheduling constraints actually applied to the pod:"
kubectl get pod -n "$NS" "$POD" -o jsonpath='{"--- requests ---\n"}{range .spec.containers[*]}{.name}{": "}{.resources.requests}{"\n"}{end}{"--- nodeSelector ---\n"}{.spec.nodeSelector}{"\n--- tolerations ---\n"}{range .spec.tolerations[*]}{.key}{"="}{.value}{":"}{.effect}{"\n"}{end}{"--- nodeAffinity ---\n"}{.spec.affinity.nodeAffinity}{"\n"}' | tee "$OUT/head_pod_constraints.txt"

echo; echo "==> Autoscaler scale-up decision (look for NotTriggerScaleUp / predicate failures):"
kubectl get events -A --field-selector reason=NotTriggerScaleUp --sort-by=.lastTimestamp 2>/dev/null | tail -20 | tee "$OUT/notriggerscaleup.log"
kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -30 >"$OUT/pod_events.log"
kubectl get configmap -n kube-system cluster-autoscaler-status -o yaml >"$OUT/ca_status.log" 2>&1

echo; echo "==> Key line from describe (FailedScheduling):"
grep -iE "FailedScheduling|untolerated|didn't match|Insufficient|scale up|nodeAffinity" "$OUT/head_pod_describe.log" | tail -15

echo; echo "Done. Share these files: head_pod_describe.log, head_pod_constraints.txt, notriggerscaleup.log"
