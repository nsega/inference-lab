#!/usr/bin/env bash
# Inject one of the three reproducible fault scenarios.
# Usage: scripts/inject.sh s1|s2|s3   (or via `make inject FAULT=s1`)
set -euo pipefail

NS=inference-lab
KCTL="kubectl --context kind-inference-lab -n $NS"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAULT="${1:?usage: inject.sh s1|s2|s3}"

write_state() {
  mkdir -p "$ROOT/lab/state"
  cat > "$ROOT/lab/state/fault.json" <<EOF
{"fault":"$1","injected_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","description":"$2"}
EOF
}

restart_epp() {
  $KCTL rollout restart deploy/epp
  $KCTL rollout status deploy/epp --timeout=120s
}

case "$FAULT" in
  s1)
    $KCTL create configmap epp-config \
      --from-file=config.yaml="$ROOT/faults/s1-epp-config.yaml" \
      --dry-run=client -o yaml | $KCTL apply -f -
    restart_epp
    write_state s1 "scorer-weight misconfig: load-aware scorers zeroed in EPP scheduler config"
    ;;
  s2)
    $KCTL patch deploy backend-2 --type strategic \
      --patch-file "$ROOT/faults/s2-backend-patch.yaml"
    $KCTL rollout status deploy/backend-2 --timeout=120s
    write_state s2 "unhealthy endpoint in rotation: backend-2 degraded (slow + intermittent errors) while still passing health checks"
    ;;
  s3)
    $KCTL create configmap epp-config \
      --from-file=config.yaml="$ROOT/faults/s3-epp-config.yaml" \
      --dry-run=client -o yaml | $KCTL apply -f -
    restart_epp
    write_state s3 "prefix-cache routing disabled: prefix-cache-aware scorer removed from EPP scheduler config"
    ;;
  *)
    echo "unknown fault: $FAULT (expected s1|s2|s3)" >&2
    exit 1
    ;;
esac

echo "injected: $FAULT"
cat "$ROOT/lab/state/fault.json"
