# System Specification

Requirement register, system model, and component inventory. Requirement IDs are stable and referenced from every other document.

---

## 1. System model

### 1.1 Tiers

```
┌─ EDGE ──────────────────────────────────────────────┐
│  Satellites (ESP32-S3, one per room)                │
│  wake word · audio capture · playback · local UI    │
│  IoT VLAN — no WAN, ever                            │
└──────────────────────┬──────────────────────────────┘
                       │ ESPHome native API (TCP, noise-encrypted)
┌─ ORCHESTRATION ──────┴──────────────────────────────┐
│  NUC — the availability tier                        │
│  Home Assistant · Memory Service · Model Router     │
│  Tool Services · Vector DB client · Observability   │
│  Server VLAN — default-deny egress + named holes    │
└──────────────────────┬──────────────────────────────┘
                       │ HTTP/OpenAI-compatible + Wyoming
┌─ COMPUTE ────────────┴──────────────────────────────┐
│  DGX Spark — the compute tier                       │
│  LLM · VLM · STT · TTS · Embeddings · Qdrant        │
│  Scheduled: LoRA training, batch jobs               │
│  Server VLAN — egress opened manually for pulls     │
└─────────────────────────────────────────────────────┘
```

**Placement rule:** anything whose failure should not take down the house lives on the NUC. Anything that needs the GPU lives on the Spark. There is no third option, and no service spans both.

### 1.2 Principals

| Principal | Definition | Memory access |
|---|---|---|
| `owner` | Enrolled, speaker-identified household member | Full read/write to own + household namespace |
| `household` | Any enrolled member | Read/write household namespace |
| `guest` | Unidentified speaker, or speaker on a satellite in guest mode | Household read only; **no writes**, no personal/financial retrieval |
| `system` | Automations, scheduled jobs | Household namespace, no personal |

Unidentified speech resolves to `guest`. This is a fail-safe default, not an error state — see `MEMORY-SUBSYSTEM.md §4`.

### 1.3 Data classes

A lattice ordered by sensitivity. Every context fragment entering an inference request carries exactly one class; the request's effective class is the join of its fragments.

```
                    BIOMETRIC          (raw audio, camera frames, voice embeddings)
                   /         \
            FINANCIAL      PERSONAL     (ledgers, holdings) (docs, notes, calendar, memories)
                   \         /
                   HOUSEHOLD            (entity states, sensor history, automations)
                       |
                    PUBLIC              (general knowledge, web search results)
```

`allowed_backends(PUBLIC) = {local, cloud}`. For every other class, `= {local}`. Enforcement in `SECURITY-MODEL.md §3`.

---

## 2. Functional requirements

### FR-1 — Voice interaction

| ID | Requirement | Acceptance |
|---|---|---|
| **FR-1.1** | Wake word detected on-device; no audio leaves the satellite before a wake event | Packet capture shows zero audio egress while idle |
| **FR-1.2** | Commands resolve against the room the satellite is in | "Turn off the lights" in the office affects only office lights |
| **FR-1.3** | Barge-in: speaking the wake word during TTS playback interrupts it | Interrupt succeeds ≥90% of attempts at 2 m, normal speech volume |
| **FR-1.4** | Open-domain question answering | Correct, non-hallucinated answers on a 50-question smoke corpus |
| **FR-1.5** | Entity control over exposed Home Assistant devices | 95% task success on a 100-command corpus |
| **FR-1.6** | Speaker identification for enrolled members | ≥90% correct attribution, ≤2% false attribution to wrong owner |
| **FR-1.7** | Guest mode, manually or automatically entered, visibly indicated | Indicator legible at 3 m; no personal retrieval occurs while active |
| **FR-1.8** | Response streaming: playback begins before generation completes | First audio emitted at first sentence boundary, not end of response |

### FR-2 — Memory

| ID | Requirement | Acceptance |
|---|---|---|
| **FR-2.1** | Facts persist across sessions, reboots, and model swaps | Fact stated Monday is recalled after a Wednesday restart |
| **FR-2.2** | Per-principal isolation | Guest session retrieves zero `owner`-namespace memories |
| **FR-2.3** | Contradictions resolved in favour of recency, with the superseded fact retained | Updating a preference changes the answer; history remains auditable |
| **FR-2.4** | Memories are inspectable and deletable by the owner | UI or CLI lists, edits, deletes; deletion is immediate and total |
| **FR-2.5** | Memory writes are attributable | Every stored memory records source turn, principal, timestamp, confidence |

### FR-3 — Perception

| ID | Requirement | Acceptance |
|---|---|---|
| **FR-3.1** | Camera events produce natural-language descriptions on demand | Description available as an HA entity within 5 s of trigger |
| **FR-3.2** | VLM output enters downstream prompts as **structured data**, never as free instruction text | Injected sign in frame does not alter assistant behaviour — see `SEC-2` |

### FR-4 — Knowledge

| ID | Requirement | Acceptance |
|---|---|---|
| **FR-4.1** | Retrieval over personal document corpus | Answers cite the source document; nightly re-index of changed pages |
| **FR-4.2** | Current-information queries via self-hosted search | Answers questions whose facts postdate the model cutoff |

### FR-5 — Finance *(deferred; see ARCHITECTURE.md §5)*

| ID | Requirement |
|---|---|
| **FR-5.1** | Spending and cash-flow queries against a transaction ledger |
| **FR-5.2** | Portfolio and net-worth queries against a holdings tracker |
| **FR-5.3** | Both pinned to local backends unconditionally (`SEC-1`) |

### FR-6 — Displays

| ID | Requirement |
|---|---|
| **FR-6.1** | Render a named dashboard to a named screen on request, without internet |
| **FR-6.2** | Wake the display and select input via HDMI-CEC |

---

## 3. Non-functional requirements

### NFR-1 — Latency

Measured as **Time-To-Response (TTR)**: end of user speech → first audio sample of the reply. Full derivation in `LATENCY-BUDGET.md`.

| ID | Requirement | Target |
|---|---|---|
| **NFR-1.1** | TTR for entity control | p50 ≤ 800 ms, p95 ≤ 1200 ms |
| **NFR-1.2** | TTR for knowledge queries | p50 ≤ 1500 ms, p95 ≤ 2500 ms |
| **NFR-1.3** | TTR degradation under background GPU load | p95 inflation ≤ 25% vs. idle |
| **NFR-1.4** | Wake-word false accepts | ≤ 1 per satellite per 24 h |
| **NFR-1.5** | Wake-word false rejects | ≤ 5% at 3 m, conversational volume |

### NFR-2 — Availability

| ID | Requirement |
|---|---|
| **NFR-2.1** | Spark unavailable ⇒ voice control still functions via Home Assistant's built-in intent matcher, with degraded scope and an audible indication |
| **NFR-2.2** | NUC services survive Spark reboot, model reload, and OOM without restart |
| **NFR-2.3** | Satellite loses network ⇒ reconnects automatically, no manual reflash |
| **NFR-2.4** | No single Docker container restart requires a full-stack restart |

### NFR-3 — Capacity

| ID | Requirement |
|---|---|
| **NFR-3.1** | Support ≥8 satellites, ≥2 concurrent voice sessions without SLO violation |
| **NFR-3.2** | Resident model set fits in unified memory with ≥40 GB free for scheduled training |

### NFR-4 — Maintainability

| ID | Requirement |
|---|---|
| **NFR-4.1** | All service configuration in version control; no undocumented UI-only state |
| **NFR-4.2** | Full stack redeployable from repo + backups onto replacement hardware |
| **NFR-4.3** | Model versions pinned by digest, not tag |

---

## 4. Software component inventory

### 4.1 Compute tier (Spark)

| Component | Implementation | Interface | Notes |
|---|---|---|---|
| Container runtime | Docker + NVIDIA Container Toolkit | — | aarch64 images required throughout |
| LLM serving | **vLLM** (default) or **SGLang** — decision in §4.4 | OpenAI-compatible HTTP `:8000` | Not Ollama. The SLOs require scheduling control it does not have — see §4.4 |
| Fast LLM | Qwen3-30B-A3B (MoE, ~3.3 B active), Q4 | model name `local/fast` | Voice default |
| Deep LLM | gpt-oss-120b MXFP4 (MoE, ~5.1 B active) | `local/deep` | Explicit escalation only |
| VLM | Qwen2.5-VL 7B | `local/vision` | 7B chosen to preserve training headroom — `NFR-3.2` |
| STT | faster-whisper `large-v3-turbo`, GPU | Wyoming `:10300` | On GPU, not NUC CPU; this is worth ~1 s of TTR |
| TTS | Piper → Kokoro | Wyoming `:10200` | Must support streaming/chunked output for `FR-1.8` |
| Embeddings | bge-m3 | via Ollama | Shared by RAG and memory |
| Vector DB | Qdrant | gRPC/HTTP `:6333` | Collections: `docs`, `memory` |
| Reranker | bge-reranker-v2-m3 | — | Optional; improves memory precision at ~30 ms cost |
| Training | HF `peft` + `trl`, LoRA/QLoRA | scheduled job | Off-peak only, admission-controlled |

### 4.2 Orchestration tier (NUC)

| Component | Implementation | Interface | Notes |
|---|---|---|---|
| Automation hub | Home Assistant Core | `:8123` | Availability tier; owns entity state and Assist pipeline |
| Firmware build/OTA | ESPHome | `:6052` | Satellite firmware lifecycle |
| Model router | **LiteLLM** | OpenAI-compatible `:4000` | Single endpoint for all callers. **Policy enforcement point** — `SEC-1` |
| Memory service | Custom (FastAPI) | HTTP, see §5.1 | Sits between HA and router; retrieval + extraction + reflection |
| Tool services | Custom (FastAPI) | HTTP + MCP | Finance, search, house queries |
| Search | SearXNG | `:8080` | Local-first current-information source (`FR-4.2`) |
| Chat UI | Open WebUI | `:3000` | Keyboard interface; same router endpoint |
| Ledger | Firefly III + Postgres | REST | Deferred phase |
| Portfolio | Ghostfolio + Postgres + Redis | REST | Deferred phase |
| Metrics | Prometheus + Grafana | `:9090` / `:3001` | `OPS-1` |
| Logs | Loki + Promtail | `:3100` | Structured, correlated by trace ID |
| Tracing | OpenTelemetry Collector + Tempo/Jaeger | `:4317` | Per-stage TTR attribution — mandatory for `NFR-1` |
| Backup | restic → NAS + offsite | scheduled | `OPS-2` |
| Secrets | SOPS + age, or Vault | — | No plaintext keys in the repo |

### 4.3 Edge tier (satellites)

| Component | Implementation | Notes |
|---|---|---|
| Firmware | ESPHome | Config generated per room from a shared template |
| Wake word | microWakeWord, on-device | Never streams pre-wake audio (`FR-1.1`) |
| Audio ADC | ES7210 (`audio_adc` platform) | 4-channel: 2 mic + speaker loopback reference |
| Audio DAC | ES8311 | Shares the I2S bus with the ADC — known integration friction |
| Echo cancellation | `esp_audio_stack` + `esp_aec` external components | Needed for `FR-1.3`; costs ~7 ms of a 16 ms frame **[verify]** |
| Local UI | LVGL | Listening-state indicator is a hard requirement, not decoration |
| Display kiosk (TV) | Fully Kiosk Browser or Chromium kiosk | `FR-6.1`; local URLs only |

### 4.4 Serving engine selection

**Ollama is rejected for the serving path.** It is a fine desktop convenience and a fast way to pull a model, but it is not a serving stack, and three requirements above rule it out directly:

| Requirement | What it needs | Ollama |
|---|---|---|
| `NFR-1.3` — ≤25% p95 TTR inflation under background load | Request priority + preemption, so a voice turn jumps a queued VLM or batch job | No priority scheduling |
| `NFR-1.1/1.2` — TTR budget dominated by prefill | **Prefix caching** across turns, and **chunked prefill** so one long prefill can't block another request's decode | Neither |
| `NFR-4.3` — models pinned by digest | Explicit, auditable weight and quantization provenance | Registry tags obscure exact quant lineage |

The usual reason to start with Ollama — Home Assistant's native Ollama integration — **does not apply here.** Every caller targets LiteLLM (§5.2); HA never speaks to the model server directly. That rationale was inherited from an earlier revision of the plan written before the router existed, and does not survive it.

**Prefix caching is the single most valuable serving feature for this workload.** Every voice turn carries a large, near-identical prefix — system prompt, tool schemas, and the exposed Home Assistant entity list, plausibly 2–6 k tokens that change rarely. Caching it converts most of the prefill into a cache hit and buys down the dominant term in the TTR budget (`LATENCY-BUDGET.md §2`). This should drive engine choice more than raw throughput does.

| Candidate | Case for | Case against |
|---|---|---|
| **vLLM** *(default)* | Continuous batching, PagedAttention, automatic prefix caching, chunked prefill, priority scheduling, preemption. NVIDIA publishes ARM64 containers. Broad MoE support. | Heavier operationally; aarch64 + Blackwell build currency needs confirming **[verify]** |
| **SGLang** | RadixAttention prefix caching suits a prefix-heavy workload well. Strong structured-output support, useful for `FR-3.2`. | aarch64/Blackwell support less certain than vLLM's **[verify]** |
| **llama.cpp server** | Simple, good GGUF/unified-memory story and Blackwell support. Adequate for 2 concurrent sessions. | No priority scheduling — fails `NFR-1.3`. Fallback only. |
| ~~Ollama~~ | — | Rejected above. |

**Decision:** vLLM by default. Benchmark SGLang against it on the real hardware before committing, with prefix-cache hit rate and p95 TTFT under mixed load as the deciding metrics. llama.cpp is the fallback if neither builds cleanly on aarch64.

---

## 5. Interface contracts

### 5.1 Memory Service

The one genuinely custom component in the critical path. It must be fast enough to sit inline (`LATENCY-BUDGET.md §2`) and must enforce principal isolation (`FR-2.2`).

```http
POST /v1/context
```
```jsonc
// request
{
  "principal": "owner:tarun",       // or "guest"
  "room": "office",
  "utterance": "what did I say about the garage door",
  "budget_tokens": 512,             // hard cap on injected context
  "classes_permitted": ["HOUSEHOLD", "PERSONAL"]
}
// response
{
  "fragments": [
    { "text": "...", "class": "PERSONAL", "source": "mem:01J...", "score": 0.82 }
  ],
  "effective_class": "PERSONAL",    // join over fragments — drives routing
  "tokens_used": 337,
  "latency_ms": 24
}
```

```http
POST /v1/observe     // post-turn fact extraction; async, off critical path
POST /v1/reflect     // nightly consolidation; batch
GET  /v1/memories    // inspection (FR-2.4)
DELETE /v1/memories/{id}
```

**Contract:** `/v1/context` must return within **50 ms p95** or return empty rather than block the voice path. Degraded retrieval is always preferable to a late response.

### 5.2 Model Router

Every inference caller in the system uses this endpoint and no other.

```
POST /v1/chat/completions        # OpenAI-compatible
```

Non-standard requirement: requests carry `x-clanker-class` and `x-clanker-principal` headers. A pre-call hook rejects any request whose class is not in `allowed_backends` for the resolved model. Rejection is a hard 403, never a silent downgrade — see `SECURITY-MODEL.md §3`.

### 5.3 Tool services

Exposed to the model via Home Assistant's MCP integration. Every tool declares its data class; the router uses the highest class among invoked tools when computing routing eligibility.

```python
@tool(data_class="FINANCIAL", principals=["owner"])
def get_spending_velocity(timeframe: str) -> SpendingSummary: ...

@tool(data_class="HOUSEHOLD", principals=["owner", "household", "guest"])
def get_entity_state(entity_id: str) -> State: ...
```

---

## 6. Open specification items

| # | Item | Blocks |
|---|---|---|
| 1 | Satellite hardware selection — Voice PE vs Waveshare 4.3C vs ESP-VoCat A/B | `FR-1.3`, `FR-1.7`, edge firmware work |
| 2 | Speaker identification approach — voice embedding vs. explicit enrolment vs. hybrid | `FR-1.6`, and `BIOMETRIC` class handling |
| 3 | vLLM vs SGLang bake-off on aarch64/Blackwell — prefix-cache hit rate and p95 TTFT under mixed load (§4.4) | `NFR-1.1`, `NFR-1.3` |
| 4 | Whether `local/deep` stays resident or loads on demand | `NFR-3.2` |
| 5 | Reflection job design — consolidation policy and decay function | `FR-2.3` |
