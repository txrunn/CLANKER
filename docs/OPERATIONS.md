# Operations

SLOs, observability, failure behaviour, lifecycle, and recovery. Satisfies `OPS-*` and the availability requirements in `NFR-2`.

---

## 1. Service level objectives

| SLO | Target | Window | Source requirement |
|---|---|---|---|
| Voice availability | 99.5% of wake events produce a response | 30 d | `NFR-2.1` |
| Control TTR | p95 ≤ 1200 ms | 7 d | `NFR-1.1` |
| Knowledge TTR | p95 ≤ 2500 ms | 7 d | `NFR-1.2` |
| TTR under load | p95 ≤ +25% vs idle baseline | 7 d | `NFR-1.3` |
| Task success | ≥95% on the standing command corpus | per release | `FR-1.5` |
| Wake-word false accepts | ≤1 per satellite per 24 h | 7 d | `NFR-1.4` |
| Memory retrieval | p95 ≤ 50 ms, or empty | 7 d | `SYSTEM-SPEC.md §5.1` |

**Error budget.** 99.5% over 30 days is ~3.6 hours of unavailability. Scheduled Spark reboots for model changes consume it, which is exactly why `NFR-2.1` requires the fast path to survive them — a Spark reboot should cost degraded capability, not downtime.

An SLO nobody looks at is decoration. §2 is what makes these enforceable.

---

## 2. Observability — `OPS-1`

### 2.1 Tracing is mandatory, not optional

`NFR-1.1`–`NFR-1.3` are stated as percentiles of a decomposed budget. Without per-stage attribution there is no way to answer "why was that turn slow," which is the only operational question that will ever be asked about this system.

**One trace per voice turn**, spanning every tier:

```
turn ─┬─ wake_detected            (satellite)
      ├─ audio_stream             (satellite → HA)
      ├─ vad_endpoint             (HA)
      ├─ stt                      (Spark)
      ├─ memory_retrieve          (NUC → Spark)   ← 50 ms budget
      ├─ route_policy_check       (LiteLLM)       ← SEC-1 decision recorded
      ├─ llm_prefill              (vLLM)          ← prefix-cache hit/miss
      ├─ llm_decode_first_sentence(vLLM)
      ├─ tts_first_chunk          (Spark)
      └─ playback_start           (satellite)
```

Trace ID propagates from the satellite through every hop. OpenTelemetry Collector → Tempo (or Jaeger). Every stage in `LATENCY-BUDGET.md §2` must appear as a span, or that document cannot be validated.

### 2.2 Metrics

| Metric | Type | Why |
|---|---|---|
| `ttr_seconds{path=fast\|slow}` | histogram | The primary SLO |
| `stage_duration_seconds{stage}` | histogram | Budget attribution |
| `prefix_cache_hit_ratio` | gauge | Validates the §4 assumption that engine choice rests on |
| `gpu_queue_depth{priority}` | gauge | Contention visibility |
| `gpu_memory_used_bytes` | gauge | `NFR-3.2` headroom |
| `wake_events_total{satellite,outcome}` | counter | False accept/reject rates |
| `policy_violations_total{class,backend}` | counter | **Should be zero.** Non-zero is a `SEC-1` incident |
| `memory_retrieval_empty_total{reason}` | counter | Budget misses vs. genuine no-results |
| `tool_calls_total{tool,tier,outcome}` | counter | Actuator audit trail |
| `guest_mode_active` | gauge per satellite | `FR-1.7` |

Prometheus scrape, Grafana dashboards. One dashboard per audience: **voice health** (TTR breakdown, SLO burn), **capacity** (GPU memory, queue depth, model residency), **security** (policy violations, Tier-2 invocations, guest sessions).

### 2.3 Logs

Structured JSON to Loki, correlated by trace ID. **Never log:** raw audio, transcripts at `PERSONAL`+ sensitivity, credentials. Log the *decision* (`retrieved 3 fragments, class=PERSONAL`), not the content.

### 2.4 Alerting

Alert on symptoms, not causes. Three alerts to start:

| Alert | Condition | Severity |
|---|---|---|
| Voice path down | No successful turn in 15 min while satellites are online | page |
| SLO burn | Control TTR p95 > 1200 ms for 30 min | notify |
| Policy violation | `policy_violations_total` increases | page |

That last one pages because it means either a bug in the enforcement path or an actual attempt to route sensitive data off-box. Both warrant waking up for.

---

## 3. Failure modes and degradation

`NFR-2.1` requires graceful degradation, not fault tolerance. The system is a house assistant, not a pacemaker — it may lose capability, but it must not lose the ability to turn on a light.

| Failure | Behaviour | Recovery |
|---|---|---|
| **Spark down / rebooting** | HA falls back to built-in intent matching. Control commands work; knowledge queries fail with an **audible** "my brain is offline" rather than silence | Auto on Spark return |
| **LLM model unloaded** | Same as above for the affected model tier | vLLM reload; keep models resident to avoid this |
| **LiteLLM down** | All model access fails; fast path unaffected | Container restart; it is stateless |
| **Qdrant down** | Memory and RAG return empty; assistant answers without context | Restart; restore if data lost |
| **STT down** | Voice unusable. This is the hard dependency | Page-worthy |
| **TTS down** | Fall back to a second voice, or text-only on satellites with screens | |
| **Satellite offline** | That room only. Others unaffected | Auto-reconnect (`NFR-2.3`) |
| **NUC down** | Everything down. This is the single point of failure | Documented rebuild (§5) |
| **Network partition Spark↔NUC** | Same as Spark down | |
| **Memory service down** | Retrieval returns empty; voice path continues | Restart |

**Explicit non-goal:** NUC high availability. A second NUC doubles operational complexity to protect against a failure mode whose recovery is "restore from backup and boot," and this is a house, not a datacenter. The mitigation is a tested restore (§5), not redundancy.

**Failures must be audible.** A voice assistant that silently does nothing is indistinguishable from one that did not hear you, and produces the worst user behaviour: repeating louder. Every degraded state gets a distinct, brief spoken or tonal indication.

---

## 4. Model and config lifecycle

### 4.1 Pinning — `NFR-4.3`, `SEC-7`

Models are pinned by **digest**, never tag. Container images likewise. A `models.lock` file in the repo records, for every model: source repository, revision hash, quantization method and provenance, file checksums, and the date it was promoted.

Quantization provenance matters more than it looks. "Qwen3-30B-A3B Q4" is not a specification — who quantized it, with what calibration data, in what format? Two files with the same name can differ measurably in quality. Record the exact artifact.

### 4.2 Promotion

No model reaches the voice path without passing `TEST-PLAN.md`'s regression suite. The upgrade path:

```
pull + verify checksum → load alongside current (memory allows it)
  → run command corpus + latency benchmark
  → compare against incumbent
  → promote by flipping the LiteLLM alias
  → keep the previous digest resident for one week for instant rollback
```

Aliases (`local/fast`) are what callers reference; the digest behind an alias is what changes. Nothing outside LiteLLM's config ever names a specific model version.

### 4.3 Configuration

All service configuration in this repo. Home Assistant is the awkward case — much of its state is UI-managed — so the automation and Assist pipeline configuration that this system depends on should be YAML-defined and committed, accepting that some HA state stays in its own database.

Secrets via SOPS+age (`SEC-9`). **This repo is intended to be public; a plaintext credential committed once is compromised permanently.**

---

## 5. Backup and recovery — `OPS-2`

### 5.1 What is actually irreplaceable

| Data | Replaceable? | Priority |
|---|---|---|
| **Memory store (Qdrant `memory`)** | **No** — accumulated over months, cannot be re-derived | **Critical** |
| Home Assistant config + database | No — history and automations | Critical |
| Finance databases | Partially — re-importable, painfully | High |
| RAG index | Yes — re-embeddable from source documents | Low |
| Model weights | Yes — re-downloadable | None |
| Container images | Yes | None |

The insight worth internalizing: **the config and the memory are the project.** The models are commodities. Back up accordingly — and note that nothing on the critical list lives on the Spark, which is the machine most likely to be wiped during experimentation.

### 5.2 Policy

- Nightly restic snapshot → NAS; weekly → offsite encrypted
- 30 daily, 12 monthly retained
- **Restore tested quarterly.** An untested backup is a hypothesis, not a backup
- Recovery target: full stack on replacement hardware from repo + backups within one day (`NFR-4.2`)

### 5.3 Runbooks to write

Deferred until the corresponding component exists, but tracked here so they are not forgotten: satellite reflash, model rollback, Qdrant restore, full NUC rebuild, egress-hole audit, and rotating the cloud API key.
