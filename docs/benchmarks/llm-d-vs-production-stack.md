# llm-d vs vLLM production-stack — single-GPU router benchmark

**Date:** 2026-06-09 · **Cluster:** minikube `mini-platform`, k8s v1.28.0, 1 node
· **GPU:** 1× NVIDIA RTX 5090 (32GB) · **Model:** `unsloth/Qwen3.6-27B-NVFP4`
(served as `qwen3.6-27b`) · **Engine:** vLLM 0.22.1 (`vllm/vllm-openai:latest`,
same image ID for both stacks)

## What was compared

Three serving paths in front of the **identical** vLLM engine configuration
(fp8 KV cache, `--enforce-eager`, 8k context, prefix caching, 0.95 GPU memory
utilization, weights from the same HF-cache PVC):

| Path | Entry point | Routing layer |
| --- | --- | --- |
| `direct` | `vllm-qwen-engine-service:80` | none (baseline) |
| `prodrouter` | `vllm-router-service:80` | production-stack router (session routing) |
| `llmd` | `llm-d-epp:80` | GAIE standalone v1.5.0: Envoy sidecar → EPP ext-proc (llm-d inference-scheduler v0.8.0, optimized-baseline scorers: prefix-cache 3, queue 2, kv-util 2, no-hit-lru 2) |

## Method

`vllm bench serve` from an in-cluster pod ([tools/vllm-bench.yaml](../../tools/vllm-bench.yaml)),
ShareGPT V3 dataset, **chat-completions** endpoint (the path LiteLLM/Open WebUI
use), closed loop at fixed concurrency, `--seed 42` so all three paths receive
the **same sampled prompts** per concurrency level. Warmup run discarded per
path. Raw JSON in [results/](results/).

| Run | prompts | max concurrency |
| --- | --- | --- |
| c1 | 16 | 1 |
| c8 | 96 | 8 |
| c32 | 192 | 32 |

All 9 runs: **0 failed requests**.

## Results

### Output token throughput (tok/s) — higher is better

| Concurrency | direct | prodrouter | llm-d |
| --- | --- | --- | --- |
| 1 | 23.9 | 23.5 | 23.6 |
| 8 | 159.4 | 155.4 | 157.0 |
| 32 | 324.8 | 327.5 | **312.1 (−4.7% vs prodrouter)** |

### TTFT median / p99 (ms) — lower is better

| Concurrency | direct | prodrouter | llm-d |
| --- | --- | --- | --- |
| 1 | 145 / 264 | 136 / 222 | **177 / 235** |
| 8 | 157 / 308 | 160 / 385 | 159 / 353 |
| 32 | 8098 / 14539 | 8036 / 14180 | 8361 / 15194 |

### TPOT median / ITL p99 (ms) — lower is better

| Concurrency | direct | prodrouter | llm-d |
| --- | --- | --- | --- |
| 1 | 41.5 / 47.3 | 42.2 / 48.1 | 41.7 / 47.8 |
| 8 | 45.2 / 65.3 | 46.0 / 68.0 | 46.0 / 66.7 |
| 32 | 46.6 / 74.1 | 45.6 / 72.5 | 48.2 / 82.6 |

## Reading the numbers

- **At c1 and c8 the three paths are within run-to-run noise** for throughput
  and decode-phase metrics. The production-stack router adds no measurable
  overhead over hitting the engine directly.
- **llm-d adds ~40ms TTFT at c1** (177ms vs ~140ms): the extra hop through
  Envoy's ext-proc filter streams full request/response bodies through the EPP
  (`FULL_DUPLEX_STREAMED`) so the scheduler can score endpoints — a per-request
  tax the simple HTTP-proxy router does not pay.
- **At c32 (saturated engine) llm-d trails by ~4.7% throughput** with slightly
  fatter tail latencies (ITL p99 83ms vs 73ms). The Envoy sidecar ran with
  deliberately small resources (500m CPU request, `--concurrency 4`); some of
  this gap is likely recoverable by giving the sidecar more CPU.
- TTFT at c32 is ~8s for everyone — that is engine prefill queueing at
  saturation (27B, eager mode, one GPU), not routing.

## The important caveat

**One replica cannot show llm-d's value proposition.** With a single decode pod
there is nothing to schedule: prefix-cache-aware and load-aware scoring always
pick the same endpoint, so this benchmark measures only the *cost* of llm-d's
routing machinery, never its *benefit*. llm-d's wins (per llm-d's own
optimized-baseline results) come from multi-replica deployments where
prefix-cache-aware placement avoids redundant KV recomputation, plus P/D
disaggregation and wide-EP at larger scale. On this single-GPU node the
production-stack router is the sensible default; revisit llm-d if the platform
grows to multiple GPU replicas.

## Reproducing

```bash
# Swap serving paths (one commit): flip enabled on the two llm-d apps and set
# vllm replicaCount 0 in minikube/values/vllm-values.yaml; push; Argo swaps the
# GPU. Weights are shared via the vllm-qwen-storage-claim PVC (~3 min swap).

kubectl -n mini-platform apply -f tools/vllm-bench.yaml
kubectl -n mini-platform cp ShareGPT_V3_unfiltered_cleaned_split.json vllm-bench:/bench/sharegpt.json
kubectl -n mini-platform exec vllm-bench -- vllm bench serve \
  --backend openai-chat --endpoint /v1/chat/completions \
  --base-url http://llm-d-epp \
  --model qwen3.6-27b --tokenizer unsloth/Qwen3.6-27B-NVFP4 \
  --dataset-name sharegpt --dataset-path /bench/sharegpt.json \
  --num-prompts 192 --max-concurrency 32 --seed 42
```
