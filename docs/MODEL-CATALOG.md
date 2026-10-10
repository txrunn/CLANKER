# Model Catalog

Which models the inference tenant serves on the Spark, why, how much memory each gets, and the contract every caller follows. The machine-readable version is [`infra/catalog/models.yaml`](../infra/catalog/models.yaml); this document is its rationale. Supersedes the model rows in `ARCHITECTURE.md §3`, `§13.2` and `SYSTEM-SPEC.md §4.1` (amended to point here).

Figures not marked **[measured]** are estimates or third-party measurements, per the repo convention.

---

## 1. Constraints that pick the models

- **Capacity-rich, bandwidth-poor.** 128 GB unified memory (~119 GiB visible to CUDA) at 273 GB/s. Token generation is bandwidth-bound, so mixture-of-experts models with few active parameters per token are the only large models fast enough for voice (`LATENCY-BUDGET.md`).
- **No MIG.** The voice path and batch work share one GPU; contention is managed by vLLM priority scheduling, not partitioning.
- **One copy per model.** Other projects on the host call these endpoints rather than loading their own copy; two copies of a 63 GB model do not fit. The catalog belongs to C.L.A.N.K.E.R.; the models were chosen so they also serve stratum well (§2).
- **Blackwell-native formats.** NVFP4 and MXFP4 run on GB10 tensor cores directly; they are preferred over formats that dequantize.

## 2. The second caller: stratum / mLLM

stratum (the semantic layer of the mLLM project) labels news, think-tank publications, and transcripts: sentiment in `[-1, +1]`, `circuit ∈ {money, productive, consumption, mixed}`, policy stance per question, sanctions-rerouting stage, with an evidence span and self-reported confidence. Its label accuracy is close to mission-critical, because every downstream event study conditions on it. What that demands of a model, in order:

1. **Instruction-following and schema adherence over long inputs.** Labels must parse every time; served with JSON-schema guided decoding (§4).
2. **Calibration you can measure.** Not "high confidence", but confidence that tracks agreement with a gold set.
3. **Model diversity.** The cheapest calibration signal available locally is agreement between two independently trained model families. This is why the catalog keeps two different families resident or on demand rather than two sizes of one family.
4. **Reproducible identity.** A label records exactly which weights produced it (§4).
5. **Throughput off-peak.** Batch labelling runs overnight at low priority and must tolerate preemption by the voice path.

Raw speed matters much less to stratum than to voice; accuracy, schema adherence, and diversity matter much more. The selection below satisfies both.

## 3. The catalog

| Alias | Model | Format, size | Placement | GPU share | Callers |
|---|---|---|---|---|---|
| `local/fast` | [`nvidia/Qwen3.6-35B-A3B-NVFP4`](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4) | NVFP4, ~23.4 GB | resident | 0.24 | voice, stratum primary labeller |
| `local/deep` | [`openai/gpt-oss-120b`](https://huggingface.co/openai/gpt-oss-120b) | MXFP4 MoE, ~63 GB | on demand | 0.52 | escalation, stratum second-family check |
| `local/vision` | [`Qwen/Qwen3-VL-8B-Instruct-FP8`](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-FP8) **[verify] repo id** | FP8, ~10 GB | resident | 0.10 | camera pipeline |
| `local/embed` | [`BAAI/bge-m3`](https://huggingface.co/BAAI/bge-m3) | FP16, ~2.3 GB | resident | 0.03 | RAG, memory, stratum dedupe/retrieval |
| `local/rerank` | [`BAAI/bge-reranker-v2-m3`](https://huggingface.co/BAAI/bge-reranker-v2-m3) | FP16, ~2.3 GB | resident | 0.03 | memory precision, stratum retrieval |
| *(disabled)* `local/fast` | [`Qwen/Qwen3-30B-A3B-Instruct-2507-FP8`](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507-FP8) | FP8, ~31 GB | resident | 0.30 | fallback for `local/fast` |

### `local/fast` — Qwen3.6-35B-A3B, NVIDIA NVFP4 (changed)

Replaces Qwen3-30B-A3B as the always-resident tier. Same family, next generation, ~3B active parameters per token, so the latency analysis in `LATENCY-BUDGET.md` still holds.

- **Quality:** NVIDIA reports MMLU-Pro 85.0 for this checkpoint, a clear step up for both voice answers and stratum labelling.
- **Speed on GB10 (third-party):** ~77 tok/s single-stream, ~98 with 2-token MTP speculative decoding, ~299 tok/s aggregate at 8 parallel requests on vLLM ([Classmethod](https://dev.classmethod.jp/en/articles/dgx-spark-qwen3-6-35b-a3b-nvfp4-new-champion/)).
- **Memory:** ~23.4 GB of weights versus ~31 GB for the old FP8 tier, which buys KV cache and headroom.
- **Why NVIDIA's quant over Unsloth's:** in the same comparison, NVIDIA's static ModelOpt checkpoint was faster and smaller, and it comes from the hardware vendor (provenance, `SEC-7`).
- **Risk [verify]:** Qwen3.5/3.6 use a hybrid attention design (linear-attention layers plus standard attention). Prefix caching is the single most valuable serving feature for the voice path (`SYSTEM-SPEC.md §4.4`), and hybrid models have historically had weaker prefix-cache support. Acceptance measures `prefix_cache_hit_ratio` on the real voice prompt; if it is poor, enable `llm-fast-fallback` (the previous tier, already pinned in the catalog) by flipping two `enabled` flags.
- **Thinking mode:** off for voice (`chat_template_kwargs: {"enable_thinking": false}`). For stratum, thinking on vs off is a `classifier_version` choice, evaluated on the gold set, never a silent default.

### `local/deep` — gpt-oss-120b (kept)

- **Different family from `local/fast`.** OpenAI's training lineage versus Qwen's. For stratum, label agreement across the two is a calibration signal neither model can provide alone (§4).
- **Strong reasoning at ~5.1B active parameters**, native MXFP4, ~39-61 tok/s generation on GB10 depending on engine and context depth.
- **On demand,** because resident set + deep + training headroom cannot all fit (§5). Up during the overnight batch window and for explicit escalation.
- **Challenger to bake off:** NVIDIA Nemotron-3-Super-120B-A12B (NVFP4). Slower (~23 tok/s reported on one Spark, [NVIDIA forums](https://forums.developer.nvidia.com/t/nemotron-3-super-120b-a12b-nvfp4-on-single-dgx-spark-23-45-tok-s-spark-arena-com-benhmarks/370070)) but published with open training data and recipes, which is valuable provenance for a research engine. Evaluate on the stratum gold set before considering a swap; speed does not matter much for batch labelling.

### `local/vision` — Qwen3-VL-8B (changed)

Replaces Qwen2.5-VL-7B: one generation newer, similar size, so the training-headroom reasoning in `ARCHITECTURE.md §13.2` is unchanged. Its job is `FR-3.2` structured extraction (`{people, vehicles, motion, description}`), and output stays `UNTRUSTED` regardless of model (`SECURITY-MODEL.md §4.2`). Resident because cameras matter at 3 a.m., when the deep tier is also up.

### Retrieval — bge-m3 and bge-reranker-v2-m3 (kept)

Served by vLLM's pooling runner (embeddings, `/v1/rerank`), not Ollama. Both are multilingual, which stratum needs for EU sanctions and foreign-press sources.

## 4. Caller contract

Applies to every tenant that calls these endpoints. C.L.A.N.K.E.R. callers go through LiteLLM on the NUC (`SEC-1`); on-host tenants such as stratum read endpoints and the key from `/srv/<tenant>/.config/inference/endpoints.env`.

**Names.** Call aliases (`local/fast`), never repository names. Aliases are what promotion flips.

**Identity.** `GET /v1/models` returns `root: /models/<key>/<revision>`. Record that string as the model identity. For stratum it is the `model_id` in `labels` / `article_labels`; together with `prompt_hash` and `classifier_version` it makes every label traceable to exact weights.

**Priority.** Every endpoint runs `--scheduling-policy=priority`; lower numbers run first.

| Caller | `priority` |
|---|---|
| Voice turn | `0` |
| Interactive (chat UI, explicit escalation) | `5` |
| Batch (stratum labelling, reflection jobs) | `10` or higher |

**Labelling determinism (stratum).** `temperature: 0`, a fixed `seed`, and `response_format: {"type": "json_schema", ...}` so every label is schema-valid by construction. vLLM output is not bitwise-reproducible across different batch compositions; stratum's design already handles this correctly by treating labels as stored data that is never re-derived. Re-labelling means a new `classifier_version`.

**Cross-family agreement (recommended for stratum).** Label a sample, or everything that matters, with both `local/fast` and `local/deep`. Store both. Report agreement per class as part of each classifier version's evaluation, and treat disagreement as low confidence for robustness checks. This is cheap with both resident overnight and directly addresses "near mission-critical."

**Gold set.** stratum keeps a hand-labelled gold set per classifier family. Every model promotion (§6) and every derivative (§7) is scored against it before a study may pin it.

## 5. Memory budget

`gpu_memory_utilization` is each vLLM process's share of unified memory (weights + KV cache + activations). The catalog enforces `resident + largest on-demand ≤ gpu_budget (0.92)`; Terraform refuses to plan otherwise.

| State | Up | Share | ≈ GiB | Free for everything else |
|---|---|---|---|---|
| Day | fast, vision, embed, rerank | 0.40 | ~48 | ~70 GiB: STT, Qdrant, OS, **training** |
| Night batch | + deep | 0.92 | ~110 | ~9 GiB: OS, Qdrant, STT |
| Training window | day set + LoRA job | 0.40 + job | — | deep must be down |

The pick-two-of-three rule from `ARCHITECTURE.md §13.2` still holds, now as a schedule: the deep tier and LoRA training (stratum/mLLM or C.L.A.N.K.E.R. persona) never run at the same time. `NFR-3.2` (≥40 GB free for training with the resident set loaded) is met in the day state. All shares are **[verify]** until measured.

## 6. Pinning and promotion

1. `just pin-models <key>` writes the commit SHA; commit the diff.
2. `just pull` fetches it inside the egress window. The previous revision stays on disk.
3. Enable the candidate under its own key and port only if the budget allows running it alongside the incumbent; otherwise swap during a maintenance window.
4. Run `TEST-PLAN.md`'s command corpus, the latency benchmark, and the stratum gold set.
5. Promote by pointing the alias at the new entry (flip `enabled`) and `just apply`.
6. Keep the old revision for a week for instant rollback (`OPERATIONS.md §4.2`), then prune.

## 7. Derivative models (abliterated, merges, community quants)

**What.** "Abliteration" removes the direction in a model's activations that mediates refusals, producing a variant that refuses less. Tools such as Heretic automate it. Merges and community re-quantizations fall under the same policy.

**Allowed.** C.L.A.N.K.E.R.'s security never relies on a model refusing anything. The model is not a security boundary (`SECURITY-MODEL.md §1`); actuator authority, data egress, and guest isolation are enforced outside it. An abliterated model does not widen what the house can do.

**Never the default, because:**

- **It edits weights.** Abliteration measurably shifts the output distribution (usually reported as KL divergence from the base model and refusal rate). Capability loss varies by model and method and has to be measured on your tasks, not assumed.
- **It does not fix what stratum is exposed to.** On political-economy text, the risk is framing and hedging bias in labels, not refusal; news classification rarely triggers refusals. Abliteration targets refusals and can shift other behaviour unpredictably.
- **Provenance.** Derivatives are community uploads, often re-quantized (`SEC-7`). Accept safetensors only, never `trust_remote_code`, pinned revision, and record the base model revision.
- **Size.** Derivatives of quantized models are often republished in BF16 (gpt-oss-120b in BF16 does not fit) or re-quantized in a format GB10 does not run natively. Check the format against the budget.

**The gate (enforced by Terraform).** A derivative is its own catalog entry with its own alias (`local/deep-abliterated`) and port, `provenance.kind: derivative`, and starts `enabled: false`. It cannot be enabled until `provenance.evaluation` points at a report covering:

1. stratum gold-set agreement versus the upstream model, per label class;
2. the `TEST-PLAN.md` command corpus and latency;
3. refusal and over-compliance rates on the household's own prompts.

**For stratum,** a derivative may only enter as a challenger `classifier_version`; its labels are diffed against the upstream model's before any study pins it. **For voice,** whether guest-facing satellites may use one is a household policy decision, recorded in private instance config, not here.

## 8. Open verification items

| # | Item | Blocks |
|---|---|---|
| 1 | `local/fast` prefix-cache hit ratio on the real voice prompt (hybrid attention) | `NFR-1.1`, fallback decision |
| 2 | Tool-call parser for Qwen3.6 (`hermes` assumed) and reasoning-parser name for gpt-oss on the pinned vLLM | tool use |
| 3 | `Qwen/Qwen3-VL-8B-Instruct-FP8` repo id and vLLM support | `FR-3.1` |
| 4 | vLLM `aarch64` image tag naming for the pinned version | first pull |
| 5 | Measured `gpu_memory_utilization` per model, night state under 0.92 | `NFR-3.2` |
| 6 | stratum gold set exists and both families are scored on it | stratum Phase 4 |
| 7 | Nemotron-3-Super vs gpt-oss-120b on the gold set | `local/deep` choice |
