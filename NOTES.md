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

## GATE 2 — Healthy serving path

**Failure 3:** EPP in standalone selector mode (`--endpoint-selector=app=vllm-sim
--endpoint-target-ports=8000`) crash-loops with `namespace must not be empty`,
and after adding `--pool-namespace`, with `name must not be empty`.
**Root cause (verified in GIE v1.5.0 source, the version vendored by
llm-d-inference-scheduler v0.8.0):** `runner.setup()` passes `opts.PoolName`
(empty in selector mode) to `setupDatastore` instead of the POD_NAME-derived
`gknn.Name`. Upstream `main` already passes `gknn.Namespace, gknn.Name` — the
fix exists but is in no tagged release as of 2026-06-12.
**Rule:** with llm-d-inference-scheduler v0.8.0, selector standalone mode is
unusable; use InferencePool CRD mode (CRDs vendored at
`manifests/crds/gie-crds-v1.5.0.yaml`, ~1100 lines, applied by `make up`).
The Envoy side is unchanged — still a self-managed sidecar, no Gateway impl.

**Finding (config):** GIE v1.5.0 requires an explicit `dataLayer` section
(`metrics-data-source` + `core-metrics-extractor`) in the EndpointPickerConfig;
without it the queue / kv-cache scorers silently score all endpoints 0.
The llm-d sample configs omit it — do not copy them blindly.

**Check passed:** 42 requests through `http://localhost:30080` → all 200,
served by all three backends (19/14/9 split; EPP is score-based, not strict
round-robin — spreading across all backends is the expected healthy behavior).
EPP pod 2/2 Running, 0 restarts (covers the GATE 1 60s-uptime deferral).

## GATE 3/4 — Metrics + load

All four required series exist with real data while the in-cluster loadgen runs
(~5–15 rps sine wave, 70% shared prefix). Healthy baseline (2m windows):

- `vllm:num_requests_waiting` per backend: ~0
- `vllm:kv_cache_usage_perc`: 0.04–0.06
- prefix hit rate `sum(rate(vllm:prefix_cache_hits[2m]))/sum(rate(vllm:prefix_cache_queries[2m]))`: ~0.78
- P95 e2e `histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[2m])))`: ~2.3–2.4 s
- P95 TTFT: ~0.24 s

Decision: loadgen runs **in-cluster** (ConfigMap-mounted stdlib python) rather
than on the host — no port-forward to die during hours-long runs.

## GATE 5 — Fault drills (observed)

**S1** (queue/kv scorer weights → 0): within 2.5 min queue depth pinned to ONE
backend (49 vs 0/0), P95 e2e 2.4 s → 14.7 s, prefix hit rate UNCHANGED (~0.78).
Reset → baseline within 2.5 min. Note: `weight: 0` is accepted by the v1.5.0
config loader — no need for the "invert" variant.

**S2** (backend-2: TTFT 150ms→1500ms, ITL 10→40ms, 25% server_error, health
endpoint still 200): within 2.5 min P95 TTFT 0.24 s → 1.83 s, loadgen shows
~3–4% errors, b2 success rate 0.79 rps vs ~3 rps peers. Queues ~0 and hit rate
unchanged → cleanly distinguishable from S1/S3. EPP keeps b2 in rotation
(readiness passes), exactly the intended "unhealthy endpoint in rotation".

## GATE 5 — S3 tuning (two failures before symptom appeared)

**Failure 4:** with a SINGLE shared system prompt and `--kv-cache-size=1024`,
removing the prefix scorer produced NO drop in hit rate (0.78 before and
after). Cause: utilization ~5% → LRU never evicts; all three backends keep the
shared prefix permanently cached, so routing doesn't matter.

**Failure 5:** shrinking the cache to 256 blocks alone didn't help either —
the single prefix gets re-requested on every backend faster than anything can
evict it (utilization 10–20%).

**Rule:** for prefix-aware routing to be observable, the workload's prefix
working set must exceed ONE backend's KV cache while a routed subset fits.
Implemented: 12 "tenant" system prompts (~660 tokens each ≈ 41 blocks; 12 × 41
≈ 500 blocks pool-wide vs 256 per backend), Zipf-skewed popularity, 70% of
traffic. With routing each backend homes a few tenants (fits); without it
every backend sees all tenants → LRU churn → hit rate 0.69 → 0.45 within
2.5 min, kv-cache usage up on all backends, queues unchanged.

**Rule (latency model):** the sim's fixed `--time-to-first-token` cannot show
cache effects; `--prefill-time-per-token` DOES skip prefill for cached prefix
blocks (verified locally: identical 600-token prompt, 6.7 s cold vs 3.8 s
warm). Backends use `--prefill-time-per-token=2ms` so S3's hit-rate collapse
also degrades TTFT/e2e latency, as the brief expects.

## GATE 5 — final tuning + verified drill results

**Failure 6:** with `prefill-time-per-token=2ms` the baseline itself saturated
(queues 25–31 everywhere) at `--max-num-seqs=4`. Raised to 8 seats → healthy
queues back to 0. **Rule:** when changing the latency model, re-derive
capacity: seats ≥ peak_rps_per_backend × mean_service_seconds with headroom.

**Failure 7:** S1 as "weights → 0" did not pile up queues under the 12-tenant
workload (prefix affinity spreads tenants across backends; the hot backend
stayed under 8 seats because hits are fast). Switched S1 to the brief's
"invert" variant: `queue-scorer weight: -2` (negative weights are accepted by
the v1.5.0 loader). Positive feedback then drags 100% of traffic onto one
backend.

Final drill results (inject → symptom < 3 min → reset → recovery < 3 min),
healthy baseline: queues ~0, hit rate ~0.72, P95 e2e ~8.1 s, P95 TTFT ~1.9 s:

- **S1:** queue 88 on one backend, others 0.00 rps; P95 e2e 19.7 s (SLO 16 s
  breached); hit rate unchanged.
- **S2:** ~10% loadgen errors; degraded backend success rate lowest of pool;
  pool P95 e2e 14.7 s; queues ~0; hit rate unchanged. Backend stays Ready.
- **S3:** hit rate 0.72 → 0.48; kv churn on all backends; queues balanced ~0;
  no error spike. Three mutually distinguishable signatures.

## GATE 7 — Tunnel rehearsal (done early, independent of the cluster)

- `cloudflared tunnel --url http://localhost:<port>` produces a quick tunnel URL
  (`https://<random>.trycloudflare.com`) in ~10s, no account needed.
- Verified: local `python3 -m http.server 8777` reachable through the public
  trycloudflare URL (HTTP 200 via Cloudflare edge). Phone-on-cellular spot check
  still worth doing manually before Build Day, but public reachability is proven.

## GATE 6 — Repeatability

Full hands-off cycle `make down && make up && make load && make inject
FAULT=s1 && make reset && make down` passed end-to-end (exit 0, every
`kubectl wait` condition met). All five images are pre-pulled to the host
docker cache by `make pull-images` (a dependency of `up`), so Build Day needs
no large downloads. Targets are idempotent: `create configmap … --dry-run -o
yaml | apply`, `kind get clusters | grep || create`, `apply` everywhere.

## kind image loading on Docker containerd store

**Failure:** `kind load docker-image` fails with
`ctr: content digest sha256:...: not found` for every multi-arch image
(Docker Desktop with containerd image store keeps manifest-list digests kind
cannot export).
**Rule:** use `docker save --platform linux/arm64 <img> -o f.tar &&
kind load image-archive f.tar` instead. Encoded in the Makefile `up` target.

**EPP 60s-uptime note:** the EPP binary runs natively on arm64 (verified `--help` exits 0,
no exec-format/qemu involved), but it requires a kube API server to start fully, so its
60s-uptime check is performed in-cluster at GATE 2 instead of in plain docker.
