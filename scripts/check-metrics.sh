#!/usr/bin/env bash
# GATE 3 / baseline check: query the four required series from Prometheus.
# Usage: scripts/check-metrics.sh  (requires load running for meaningful values)
set -euo pipefail
PROM="${PROM:-http://localhost:30090}"

q() {
  curl -s "$PROM/api/v1/query" --data-urlencode "query=$2" | python3 -c "
import json, sys
r = json.load(sys.stdin)['data']['result']
if not r:
    print('$1: NO DATA'); sys.exit(1)
for s in r:
    lbl = s['metric'].get('backend') or s['metric'].get('pod', '')
    v = float(s['value'][1])
    print(f'$1{\"[\" + lbl + \"]\" if lbl else \"\"}: {v:.4f}')
"
}

echo "== 1. queue depth (vllm:num_requests_waiting, per backend)"
q queue_depth 'sum by (backend) (vllm:num_requests_waiting)'
echo "== 2. KV-cache utilization (vllm:kv_cache_usage_perc, per backend)"
q kv_cache 'sum by (backend) (vllm:kv_cache_usage_perc)'
echo "== 3. prefix-cache hit rate (hits/queries over 2m, pool-wide)"
q prefix_hit_rate 'sum(rate(vllm:prefix_cache_hits[2m])) / sum(rate(vllm:prefix_cache_queries[2m]))'
echo "== 4a. P95 e2e latency (s, pool-wide, 2m window)"
q p95_e2e 'histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[2m])))'
echo "== 4b. P95 TTFT (s, pool-wide, 2m window)"
q p95_ttft 'histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[2m])))'
echo "== error rate (5xx fraction per backend, 2m window)"
curl -s "$PROM/api/v1/query" --data-urlencode \
  'query=sum by (backend) (rate(vllm:request_success_total[2m]))' | python3 -c "
import json, sys
for s in json.load(sys.stdin)['data']['result']:
    print(f\"success_rps[{s['metric'].get('backend','')}]: {float(s['value'][1]):.2f}\")
"
echo "OK: all series returned data"
