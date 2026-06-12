#!/usr/bin/env python3
"""Continuous load generator for the inference-lab gateway.

- ~70% of requests share a long common system prompt (makes prefix-cache
  hit rate meaningful), 30% carry a unique system prompt.
- Mixed user-message lengths (short / medium / long).
- Rate oscillates between LOW_RPS and HIGH_RPS on a slow sine wave.
- stdlib only; designed to run for hours.
"""
import json
import math
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TARGET = os.environ.get("TARGET", "http://gateway.inference-lab.svc:80")
MODEL = os.environ.get("MODEL", "meta-llama/Llama-3.1-8B-Instruct")
LOW_RPS = float(os.environ.get("LOW_RPS", "5"))
HIGH_RPS = float(os.environ.get("HIGH_RPS", "15"))
RPS_PERIOD_S = float(os.environ.get("RPS_PERIOD_S", "300"))
PREFIX_SHARE = float(os.environ.get("PREFIX_SHARE", "0.7"))
REPORT_EVERY_S = 30

# A long shared system prompt; identical bytes on ~70% of requests so the
# prefix cache has something to hit.
SHARED_SYSTEM = (
    "You are RouteCause Lab Assistant, a careful and precise AI system that "
    "answers questions about distributed inference infrastructure. Always "
    "follow these standing instructions: (1) be concise, (2) cite which "
    "backend served you if known, (3) never fabricate metrics, (4) prefer "
    "structured answers with short bullet points, (5) if the question is "
    "ambiguous ask one clarifying question, (6) treat all latency numbers "
    "as milliseconds unless stated otherwise, (7) assume the cluster runs "
    "Kubernetes with an Envoy-fronted endpoint picker, (8) keep a neutral "
    "tone, (9) do not speculate about hardware you cannot observe, and "
    "(10) end every answer with a one-line summary. " * 3
)

WORDS = (
    "latency throughput queue cache prefix tokens routing envoy scheduler "
    "backend replica scorer picker waiting running utilization histogram "
    "gateway cluster metric scrape probe deadline jitter percentile"
).split()


def rand_text(n_words: int) -> str:
    return " ".join(random.choice(WORDS) for _ in range(n_words))


stats_lock = threading.Lock()
stats = {"ok": 0, "err": 0, "lat_sum": 0.0}


def one_request() -> None:
    shared = random.random() < PREFIX_SHARE
    system = SHARED_SYSTEM if shared else (
        f"You are assistant #{random.randrange(10**9)}. " + rand_text(60)
    )
    n_words = random.choice((8, 8, 30, 30, 30, 90, 200))
    body = json.dumps({
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": rand_text(n_words)},
        ],
        "max_tokens": random.choice((20, 40, 80)),
    }).encode()
    req = urllib.request.Request(
        f"{TARGET}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
            ok = resp.status == 200
    except Exception:
        ok = False
    dt = time.monotonic() - t0
    with stats_lock:
        stats["ok" if ok else "err"] += 1
        stats["lat_sum"] += dt


def reporter() -> None:
    last = {"ok": 0, "err": 0, "lat_sum": 0.0}
    while True:
        time.sleep(REPORT_EVERY_S)
        with stats_lock:
            cur = dict(stats)
        d_ok = cur["ok"] - last["ok"]
        d_err = cur["err"] - last["err"]
        d_lat = cur["lat_sum"] - last["lat_sum"]
        n = d_ok + d_err
        avg = (d_lat / n * 1000) if n else 0.0
        print(
            f"[loadgen] last {REPORT_EVERY_S}s: {n} reqs "
            f"({n / REPORT_EVERY_S:.1f} rps), {d_err} errors, "
            f"avg latency {avg:.0f} ms",
            flush=True,
        )
        last = cur


def main() -> None:
    print(f"[loadgen] target={TARGET} rps={LOW_RPS}..{HIGH_RPS}", flush=True)
    threading.Thread(target=reporter, daemon=True).start()
    pool = ThreadPoolExecutor(max_workers=96)
    t_start = time.monotonic()
    while True:
        phase = math.sin(2 * math.pi * (time.monotonic() - t_start) / RPS_PERIOD_S)
        rps = LOW_RPS + (HIGH_RPS - LOW_RPS) * (phase + 1) / 2
        pool.submit(one_request)
        time.sleep(1.0 / rps)


if __name__ == "__main__":
    sys.exit(main())
