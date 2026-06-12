# NOTES.md — failures, decisions, derived rules

Working log for the PREP.md gates. Every failure and the rule derived from it gets recorded here.

## GATE 0 — Toolchain

- `kind` and `cloudflared` were missing → installed via `brew install kind cloudflared`.
- Docker Desktop daemon was not running → `open -a Docker`, daemon up in ~20s.
- Smoke check passed: `kind create cluster --name smoke` → node Ready in 22s → deleted.

## GATE 1 — Image architecture (arm64)

Images pinned (both publish arm64 manifests, verified with `docker manifest inspect`):

- Backend simulator: `ghcr.io/llm-d/llm-d-inference-sim:v0.9.2`
- EPP / llm-d Router: `ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0`

**Failure 1:** sim v0.9.2 with default `--mode random` crashes at startup:
`failed to initialize random dataset: ... dial tcp [::1]:8082: connect: connection refused` —
v0.9.x random mode requires an external HF-tokenizer "render" service on :8082.
**Rule:** run the sim with `--mode echo --force-dummy-tokenizer` — no external tokenizer
dependency, deterministic responses, all metrics still real.

**Failure 2:** `--enable-kvcache` exits with `IP should be defined in the environment (POD_IP)`.
**Rule:** always set `POD_IP` env (downward API in k8s, `-e POD_IP=127.0.0.1` in plain docker).

**Finding:** sim natively exports ALL four required series — no fake exporter sidecar needed:

1. queue depth: `vllm:num_requests_waiting`
2. KV-cache utilization: `vllm:kv_cache_usage_perc` (needs `--enable-kvcache`)
3. prefix-cache: `vllm:prefix_cache_hits` / `vllm:prefix_cache_queries` (counters → rate)
4. latency histograms: `vllm:e2e_request_latency_seconds`, `vllm:time_to_first_token_seconds`

**Finding:** sim has built-in fault knobs perfect for S2: `--failure-injection-rate 0-100`,
`--failure-types`, `--time-to-first-token`/`--inter-token-latency` (latency), `--max-num-seqs`
(concurrency → queueing).

**EPP 60s-uptime note:** the EPP binary runs natively on arm64 (verified `--help` exits 0,
no exec-format/qemu involved), but it requires a kube API server to start fully, so its
60s-uptime check is performed in-cluster at GATE 2 instead of in plain docker.
