#!/usr/bin/env bash
# Inject one of the four reproducible fault scenarios.
# Usage: scripts/inject.sh s1|s2|s3|s4   (or via `make inject FAULT=s1`)
set -euo pipefail

NS=inference-lab
KCTL="kubectl --context kind-inference-lab -n $NS"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAULT="${1:?usage: inject.sh s1|s2|s3|s4}"

write_state() {
  mkdir -p "$ROOT/lab/state"
  cat > "$ROOT/lab/state/fault.json" <<EOF
{"fault":"$1","injected_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","description":"$2"}
EOF
  # Ground truth for grading only. The builder agent must never read this file;
  # restrict to owner read/write so casual/accidental access is denied and the
  # verifier can confirm non-access from the session log. (BRIEF §6, RUBRIC §A)
  chmod 600 "$ROOT/lab/state/fault.json"
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
    write_state s1 "scorer-weight misconfig: queue-depth scorer weight inverted (negative) in EPP scheduler config"
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
  s4)
    # s4 changes the traffic too, so the load generator must already exist.
    # Checked first so a missing loadgen cannot leave the fault half applied.
    $KCTL get deploy/loadgen >/dev/null 2>&1 || {
      echo "s4 needs the load generator: run 'make load' first" >&2
      exit 1
    }
    $KCTL create configmap epp-config \
      --from-file=config.yaml="$ROOT/faults/s4-epp-config.yaml" \
      --dry-run=client -o yaml | $KCTL apply -f -
    restart_epp
    # Changing the env edits the pod template, so this restarts the loadgen.
    $KCTL set env deploy/loadgen ZIPF_S=2
    $KCTL rollout status deploy/loadgen --timeout=120s
    write_state s4 "hot tenant under load-blind prefix routing: queue-depth and kv-cache scorer weights zeroed in EPP scheduler config (prefix scorer kept) while loadgen tenant skew is raised to ZIPF_S=2"
    ;;
  *)
    echo "unknown fault: $FAULT (expected s1|s2|s3|s4)" >&2
    exit 1
    ;;
esac

# Confirm the action only. Never echo fault.json — its `description` field is the
# ground-truth answer key and must not leak into any session log. (BRIEF §6, RUBRIC §A)
echo "injected: $FAULT"
