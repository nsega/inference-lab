#!/usr/bin/env bash
# Restore the healthy configuration and clear the ground-truth fault state.
set -euo pipefail

NS=inference-lab
KCTL="kubectl --context kind-inference-lab -n $NS"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Healthy EPP scheduler config
$KCTL create configmap epp-config \
  --from-file=config.yaml="$ROOT/manifests/epp-config.yaml" \
  --dry-run=client -o yaml | $KCTL apply -f -
$KCTL rollout restart deploy/epp
$KCTL rollout status deploy/epp --timeout=120s

# Healthy backend args (undoes the s2 patch, no-op otherwise)
$KCTL apply -f "$ROOT/manifests/backends.yaml"
$KCTL rollout status deploy/backend-0 deploy/backend-1 deploy/backend-2 --timeout=120s 2>/dev/null || {
  for d in backend-0 backend-1 backend-2; do
    $KCTL rollout status deploy/$d --timeout=120s
  done
}

rm -f "$ROOT/lab/state/fault.json"
echo "reset: healthy config restored, fault state cleared"
