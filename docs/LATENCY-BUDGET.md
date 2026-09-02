# Latency Budget

Why response time is the binding constraint on this system, where it goes, and what the hardware permits.

All figures are **estimates** derived from published specs and first-principles arithmetic. None are measured. Replace them as the testbed comes up.

---

## 1. Why this document exists

A voice assistant that answers correctly in four seconds is a failed voice assistant. In natural conversation, the gap between turns is on the order of 200 ms; anything past about a second reads as system lag, and past two or three seconds users start talking over it or repeating themselves. Correctness has a floor below which it stops mattering.

Every other design decision in this project — model choice, serving engine, whether memory is injected, how many satellites — is downstream of the number in this document. `NFR-1.1` and `NFR-1.2` are the requirements; this is their derivation.

**Time-To-Response (TTR)** is defined as: *end of user speech → first audio sample of the reply leaving the satellite's speaker*. Not time-to-full-response. Streaming is assumed throughout (`FR-1.8`).

---

## 2. Stage decomposition

| # | Stage | Where | Estimate (ms) | Notes |
|---|---|---|---|---|
| 1 | VAD endpointing | Satellite / HA | **300 – 500** | Silence window before "user is done" fires. Largest fixed cost in the budget. |
| 2 | Audio transport + buffering | Edge → NUC | 20 – 50 | LAN; negligible unless Wi-Fi is congested |
| 3 | STT (`large-v3-turbo`, GPU, ~3 s utterance) | Spark | 150 – 300 | On CPU this becomes 1–3 s and the budget collapses — hence GPU placement |
| 4 | Memory retrieval (embed + search + rerank) | NUC → Spark | 25 – 50 | Hard-capped at 50 ms by contract (`SYSTEM-SPEC.md §5.1`) |
| 5 | LLM prefill → first token (TTFT) | Spark | **80 – 400** | Scales with prompt length. Dominated by cache-hit rate — see §4 |
| 6 | Decode to first sentence (~15–25 tokens) | Spark | 170 – 420 | Bandwidth-bound; see §3 |
| 7 | TTS first chunk (streaming Piper) | Spark | 80 – 200 | Must be streaming. Non-streaming TTS adds the whole utterance duration |
| 8 | Return transport + playback start | NUC → Edge | 20 – 50 | |
| | **Total** | | **845 – 1970** | |

Against `NFR-1.1` (p95 ≤ 1200 ms for control) the unfavourable path misses badly. Two structural fixes follow.

---

## 3. What the hardware permits

### 3.1 Decode is bandwidth-bound

Token generation reads the active weight set from memory once per token. Therefore:

```
decode_rate ≈ memory_bandwidth / bytes_read_per_token
```

At 273 GB/s, assuming 50–70% achievable efficiency on LPDDR5X **[verify]**:

| Model | Active params | Bytes/token | Theoretical | Realistic |
|---|---|---|---|---|
| Qwen3-30B-A3B (MoE) Q4 | 3.3 B | ~1.8 GB | ~150 tok/s | **75 – 105 tok/s** |
| gpt-oss-120b MXFP4 (MoE) | 5.1 B | ~2.7 GB | ~101 tok/s | **50 – 70 tok/s** |
| Dense 8B Q4 | 8 B | ~4.4 GB | ~62 tok/s | 31 – 43 tok/s |
| Dense 70B Q4 | 70 B | ~38.5 GB | ~7 tok/s | **4 – 5 tok/s** |

**The counterintuitive result that decides model selection: a 30B MoE with 3.3 B active parameters generates faster than a dense 8B model,** because decode speed tracks *active* parameters, not total. On this hardware, sparsity is nearly free — capacity is abundant, bandwidth is not. That is why the primary model is a large-but-sparse MoE rather than a small dense model, and why any dense model above ~13B is disqualified for the voice path regardless of quality.

The dense-70B row is the reason `ARCHITECTURE.md §3` rejects that class outright: at 4–5 tok/s, a 20-token first sentence takes four seconds before TTS even starts.

### 3.2 Prefill is compute-bound

```
prefill_FLOPs ≈ 2 × active_params × prompt_tokens
```

For Qwen3-30B-A3B (3.3 B active) at an assumed ~100 TFLOPS effective on the quantized path **[verify]**:

| Prompt tokens | FLOPs | Prefill time |
|---|---|---|
| 1,000 | 6.6 T | ~66 ms |
| 2,000 | 13.2 T | ~132 ms |
| 6,000 | 39.6 T | ~396 ms |

Prefill scales linearly with prompt length, and **this system has a long prompt by construction**: system instructions, tool schemas, and the exposed Home Assistant entity list plausibly total 2–6 k tokens before a single retrieved memory is added. That is 130–400 ms of the budget spent re-reading a prompt that barely changes between turns.

---

## 4. Fix 1 — prefix caching

The long prompt is *stable*. System instructions, tool schemas, and the entity list are identical turn to turn; only the user utterance and injected memories vary. A serving engine with prefix caching computes the shared prefix once and reuses its KV cache.

| | Without prefix cache | With prefix cache |
|---|---|---|
| 6 k prompt, 5 k stable prefix | ~396 ms prefill | ~66 ms (1 k novel tokens) |

**~330 ms recovered from the single largest variable term.** This is the reason `SYSTEM-SPEC.md §4.4` selects the serving engine on prefix-cache behaviour rather than raw throughput, and the reason Ollama is disqualified.

Design consequences that follow:

1. **Keep the prefix stable.** Anything that reorders tool schemas or reshuffles the entity list on every turn destroys the cache. Serialize deterministically.
2. **Put variable content at the end.** Retrieved memories and the user utterance go last, after the stable block, so they never invalidate the prefix.
3. **Prune the entity list.** Exposing 400 entities to the model costs prefill on every miss and degrades tool-selection accuracy. Expose what is actually voice-controllable.

---

## 5. Fix 2 — two-path routing

The budget in §2 assumes every utterance reaches the LLM. Most do not need to.

"Turn off the office lights" is a deterministic intent. Home Assistant's built-in intent matcher resolves it with no model in the path at all:

| Path | Stages | Estimated TTR |
|---|---|---|
| **Fast** — deterministic intent match | 1, 2, 3, intent match (~5 ms), 7, 8 | **~555 – 800 ms** |
| **Slow** — LLM with tools | all of §2 | ~845 – 1970 ms |

Route deterministic commands down the fast path and fall through to the LLM only on a miss. This is what makes `NFR-1.1` (p95 ≤ 1200 ms for control) achievable rather than aspirational — control commands, the highest-frequency and most latency-sensitive category, largely bypass the expensive stages.

It also improves reliability: the fast path works when the Spark is down, which is exactly the degradation behaviour `NFR-2.1` requires.

**Cost:** two code paths with potentially different behaviour for the same phrasing. Mitigate by making the fast path's coverage explicit and testable (`TEST-PLAN.md`), not emergent.

---

## 6. The VAD problem

At 300–500 ms, endpointing is the largest single fixed cost, and it is pure tradeoff: shorten it and the system interrupts people mid-sentence; lengthen it and every response feels sluggish.

This cost is **unavoidable but relocatable**. Options, in order of preference:

1. **Speculative execution.** Begin STT and even prefill on the partial utterance before endpointing fires; discard if the user continues. Costs GPU work on a machine that has capacity to spare, and can hide most of the endpointing window.
2. **Adaptive endpointing.** Shorter silence window for utterances that parse as complete commands, longer for trailing-off speech.
3. **Accept it.** 300 ms fixed, tuned per room by measurement.

Start at (3), measure, and implement (1) only if p95 misses. Do not build speculative execution before there is a measurement proving it is needed.

---

## 7. Contention — the no-MIG problem

The Spark has no MIG, so the GPU cannot be partitioned. The latency-critical voice path shares one indivisible accelerator with:

| Workload | GPU demand | Latency tolerance |
|---|---|---|
| Voice turn | Bursty, small | **None** — this is the SLO |
| Camera VLM description | Bursty, large prefill (image tokens) | Seconds. Nobody is waiting on it |
| Scheduled LoRA training | Sustained, hours | Unbounded — it can be preempted freely |
| Batch reflection / re-indexing | Sustained, minutes | Unbounded |

The dangerous case is not training at 3 a.m. It is **a camera VLM call landing mid-conversation at 7 p.m.** — a large image prefill that, without mitigation, monopolizes the GPU and blows the voice SLO for the duration.

Mitigations, all required:

| Mechanism | Where | Effect |
|---|---|---|
| **Priority scheduling** | vLLM | Voice requests preempt VLM and batch work |
| **Chunked prefill** | vLLM | A large prefill is split so it cannot block another request's decode |
| **Admission control** | LiteLLM pre-call hook | Defer or reject low-priority work while an interactive turn is in flight |
| **Training gate** | Job wrapper | Training acquires a lock that voice activity releases; pauses rather than competes |
| **Model residency** | vLLM config | Keep all serving models loaded. 128 GB affords it, and a cold load mid-conversation is a multi-second stall |

`NFR-1.3` sets the acceptance bar: **p95 TTR under background load must not inflate more than 25% over idle.** That is the number that proves the scheduling design works, and it cannot be evaluated without the tracing described in `OPERATIONS.md §2`.

---

## 8. Budget summary

| Path | p50 target | p95 target | Requirement |
|---|---|---|---|
| Control command (fast path) | ≤ 800 ms | ≤ 1200 ms | `NFR-1.1` |
| Knowledge query (slow path, prefix-cached) | ≤ 1500 ms | ≤ 2500 ms | `NFR-1.2` |
| Either, under background GPU load | — | ≤ +25% vs idle | `NFR-1.3` |

**Load-bearing assumptions to validate first**, in the order they should be tested:

1. Achievable memory bandwidth as a fraction of the 273 GB/s figure — sets every decode estimate in §3.1
2. Prefix-cache hit rate under real turn patterns — §4 claims ~330 ms and the whole engine choice rests on it
3. STT latency for realistic utterance lengths on GPU — §2 stage 3
4. Fast-path coverage: what fraction of real commands avoid the LLM entirely — §5
