# inference-lab

A one-command local lab that boots an **LLM inference gateway** on
[kind](https://kind.sigs.k8s.io/), generates realistic traffic, exposes
Prometheus metrics, and can inject four reproducible routing/serving fault
scenarios.

It exists as the *target environment* for a diagnosis agent (RouteCause, built
separately): the lab produces honest, queryable symptoms; it contains **no
diagnosis logic of its own**.

```
              ┌────────────────────────── kind cluster ──────────────────────────┐
              │  gateway pod                                                     │
 curl /       │  ┌───────────────────────────┐      ┌──────────┐                 │
 loadgen ───► │  │ Envoy ── ext_proc ── EPP  │ ───► │ backend-0 │  llm-d         │
 :30080       │  │ (llm-d inference          │      │ backend-1 │  inference-sim │
              │  │  scheduler / GIE)         │      │ backend-2 │  (vLLM sim)    │
              │  └───────────────────────────┘      └──────────┘                 │
              │        Prometheus :30090  ◄── scrapes backends + EPP             │
              └──────────────────────────────────────────────────────────────────┘
```

- **Router**: [llm-d-inference-scheduler](https://github.com/llm-d/llm-d-inference-scheduler)
  v0.8.0 (the Gateway API Inference Extension endpoint picker) with a
  self-managed Envoy sidecar — no full Gateway implementation needed.
- **Backends**: 3 × [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim)
  v0.9.2 — a vLLM simulator with a real KV/prefix cache model and real
  `vllm:*` Prometheus metrics. No GPU required; runs on Apple Silicon (arm64).
- **Traffic**: an in-cluster load generator, 5–15 rps sine wave, 12 "tenant"
  system prompts with Zipf-skewed popularity (~70% of requests share a tenant
  prefix), mixed prompt/response lengths.

## Quickstart

Prereqs: docker, kind, kubectl, make (and `cloudflared` for the tunnel).
Tested on macOS / Apple Silicon.

```sh
make up      # cluster + CRDs + backends + gateway + prometheus  (~3 min warm)
make load    # start continuous traffic
make smoke   # one OpenAI-style completion through the gateway

# wait ~4 minutes for caches/metrics to settle, then:
./scripts/check-metrics.sh   # prints the four key series

make inject FAULT=s1   # or s2, s3, s4
make reset             # back to healthy
make down              # delete everything
```

Endpoints on the host:

| What | URL |
|---|---|
| Gateway (OpenAI-style API) | `http://localhost:30080/v1/chat/completions` |
| Prometheus | `http://localhost:30090` |

Model name for requests: `meta-llama/Llama-3.1-8B-Instruct` (simulated; echo mode).

## Metrics that matter

Scraped from each backend (label `backend=b0|b1|b2`) every 5s:

| Signal | Series / PromQL |
|---|---|
| Per-endpoint queue depth | `vllm:num_requests_waiting` |
| KV-cache utilization | `vllm:kv_cache_usage_perc` |
| Prefix-cache hit rate | `sum(rate(vllm:prefix_cache_hits[2m])) / sum(rate(vllm:prefix_cache_queries[2m]))` |
| P95 end-to-end latency | `histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[2m])))` |
| P95 time-to-first-token | `histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[2m])))` |
| Per-backend throughput | `sum by (backend) (rate(vllm:request_success_total[2m]))` |

The EPP's own metrics (`inference_pool_*`, `inference_objective_*`) are also
scraped, on port 9090 of the gateway pod.

## Healthy baseline and SLO

Measured with `make load` running for ≥4 minutes (2-minute windows):

| Metric | Healthy baseline |
|---|---|
| Queue depth (every backend) | ~0 |
| Prefix-cache hit rate | ~0.72 |
| P95 e2e latency | ~8 s |
| P95 TTFT | ~1.9 s |
| Errors | 0 |

**SLO: P95 e2e latency < 16 s (2× healthy baseline), error rate < 1%.**

(The absolute numbers are simulator knobs, not real-model performance; what
matters is that they are stable for hours under load and shift sharply and
reproducibly under each fault.)

## Fault scenarios

`make inject FAULT=<id>` injects exactly one; ground truth is written to
`lab/state/fault.json` (gitignored) for later scoring. `make reset` restores
health. Symptoms appear within ~3 minutes and are mutually distinguishable:

| ID | Symptom signature (what Prometheus shows) |
|---|---|
| `s1` | Queue depth piles onto **one** backend (others idle, ~0 rps); P95 e2e breaches the SLO; prefix hit rate roughly unchanged |
| `s2` | A **fraction** of requests slow and erroring, attributable to one backend (its success-rate drops, its latency histogram shifts); pool queues stay near zero |
| `s3` | Pool-wide **prefix-cache hit rate collapses** (~0.72 → ~0.45); KV-cache churn rises on all backends; latency degrades under the same load; queues stay balanced |
| `s4` | Queue depth and latency climb on **one** backend while the others **keep serving**; prefix hit rate holds or rises; errors are only client timeouts against that backend (expected signature, not yet drilled) |

What each fault actually changes is deliberately not documented here — that is
the diagnosis exercise. (Spoilers live in the `faults/` directory; don't read
them if you're playing along.)

## Exposing the gateway publicly

For demos that need a public URL (no account required):

```sh
cloudflared tunnel --url http://localhost:30080
# prints https://<random>.trycloudflare.com within ~10s
```

## Repo layout

```
manifests/   kind config, backends, gateway (EPP+Envoy), prometheus, loadgen
faults/      the four fault variants applied by scripts/inject.sh
scripts/     inject.sh, reset.sh, check-metrics.sh
load/        loadgen.py (stdlib-only, runs in-cluster) and its unit tests
lab/state/   fault.json ground truth (created on inject, cleared on reset)
NOTES.md     every failure hit while building this, and the rule derived
```
