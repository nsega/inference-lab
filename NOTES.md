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

## GATE 7 — Tunnel rehearsal (done early, independent of the cluster)

- `cloudflared tunnel --url http://localhost:<port>` produces a quick tunnel URL
  (`https://<random>.trycloudflare.com`) in ~10s, no account needed.
- Verified: local `python3 -m http.server 8777` reachable through the public
  trycloudflare URL (HTTP 200 via Cloudflare edge). Phone-on-cellular spot check
  still worth doing manually before Build Day, but public reachability is proven.

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
