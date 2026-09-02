# C.L.A.N.K.E.R. — Consolidated Architecture

Local-first home AI: voice control, RAG over personal docs, camera understanding, finance visibility, and on-demand visual output — with inference on your own hardware and auditable egress.

> Origin: consolidated in a claude.ai web session; imported into this workspace 2026-08-16.
> Amendments from the Claude Code session are in §13 — read them alongside, they modify §3, §7, and the open items.

---

## 0. Design posture

**The original "completely air-gapped" premise was dropped deliberately.** True air-gap is incompatible with three of the phases: bank data ingestion, Google Cast (which requires internet), and pulling model weights/updates. Fighting your own design to preserve the label costs you function for no privacy gain.

**Replaced with the posture that actually delivers the intent:**

- No third-party AI clouds ever see sensitive data
- All inference for private data runs LAN-only on your own hardware
- WAN egress is default-deny, opened only through a small, named, auditable allow-list

Everything below follows from that.

---

## 1. Network & egress model (UniFi Dream Machine)

| VLAN | Members | WAN policy |
|---|---|---|
| Server | DGX Spark | Default-deny; opened **manually** for model weight and container image pulls |
| Server | Homelab box / NUC (HA, LiteLLM, finance stack) | Default-deny + named allow-list below |
| IoT | Voice satellites, TV kiosks, displays | **Fully blocked** — no WAN, ever |

**The complete allow-list — four holes, not an air-gap, but intentional and auditable:**

1. **LiteLLM outbound → chosen cloud vendors** (e.g. `api.anthropic.com:443`) — only for the non-sensitive fallback agent
2. **Bank import path** — SimpleFIN Bridge, or nothing if using the CSV/OFX drop-folder method
3. **Ghostfolio → market-data provider** — required to price holdings; unavoidable if you want quotes
4. **Manual model pulls** — opened by hand, closed after

Voice satellites need no internet once adopted. The TV kiosk pattern (§7) keeps displays local, which is why the IoT VLAN can be sealed completely.

---

## 2. Hardware & the constraints that shape everything

### DGX Spark (GB10 Grace Blackwell)

| Spec | Value | Consequence |
|---|---|---|
| Unified memory | 128 GB LPDDR5X | Capacity-rich — hold many models resident |
| Memory bandwidth | 273 GB/s | **The real ceiling.** Token *generation* is bandwidth-bound |
| NVLink-C2C (CPU↔GPU, internal) | ~600 GB/s | Fast inside the box only — doesn't stretch to a second unit |
| Networking | ConnectX-7, 200 GbE | ~23–25 GB/s usable cross-node — see §9 |
| CPU | 20-core ARM (10× Cortex-X925 + 10× Cortex-A725) | **aarch64** — ARM wheel friction for some Python ecosystems |
| Power / price / storage | 240 W / ~$3,999 / 4 TB | — |

**Two hardware facts drive most decisions:**

- **Capacity-rich, bandwidth-poor.** The design favors memory coherence and size over throughput. Training and prompt-prefill are *compute*-bound and run well; token generation is *bandwidth*-bound and is where you feel the limit.
- **No MIG.** GPU partitioning was cut from this silicon. You cannot reserve a guaranteed slice for the voice pipeline — **contention is managed temporally (scheduling), not spatially (partitioning).**

### Always-on homelab box / NUC

Runs Home Assistant, LiteLLM, Firefly III, Ghostfolio, and (for the separate trading project) the IBKR gateway. The reliability tier that must survive Spark reboots, model pulls, OOMs, and experimentation.

---

## 3. Phase 1 — Inference foundation (Spark)

**Serving:** ~~Start with Ollama, migrate to vLLM if you hit contention.~~ **Superseded — see `docs/SYSTEM-SPEC.md §4.4`.** Ollama is rejected outright: it has no priority scheduling, no chunked prefill, and no prefix caching, all of which the latency SLOs depend on. The "HA integrates with Ollama natively" argument is void once every caller goes through LiteLLM. **Use vLLM**, with SGLang as the benchmark challenger and llama.cpp as the aarch64 fallback.

**Models — settled** *(amended by §13.2 — two-tier LLM)*:

| Role | Choice | Rationale |
|---|---|---|
| Primary LLM | **Qwen3-30B-A3B** (MoE) | ~3B active params/token → near-frontier quality at fast token rates on limited bandwidth |
| Vision | **Qwen2.5-VL** (7B/32B) or **Gemma 3 27B** | Gemma 3 is natively multimodal and could serve as LLM + VLM in one deployment |
| STT | **faster-whisper large-v3-turbo** via Wyoming | **Runs on the Spark GPU** — sub-second. The same model on NUC CPU adds seconds per utterance |
| TTS | **Piper** | Light enough to live anywhere |
| Embeddings | **bge-m3** (served alongside the LLM) | Shared by RAG and the memory subsystem |

**Rejected:** Llama-3-8B-Instruct (two years stale). Dense 70B models — they fit, but at ~5–10 tok/s they're unusable for voice, where latency is everything.

**Resident memory budget:**

```
LLM (Q4)        ~18–20 GB
VLM              ~6–20 GB
Whisper turbo       ~2 GB
Embeddings          ~2 GB
Piper                <1 GB
Qdrant           a few GB
─────────────────────────
Total           ~35–50 GB     →  ~75 GB headroom
```

**Endpoints** served over LAN — `http://<spark-ip>:8000` (vLLM, OpenAI-compatible). Nothing calls this directly except LiteLLM.

---

## 4. Phase 2 — Knowledge & RAG

- **Vector store:** Qdrant, or pgvector if you already run Postgres
- **Ingestion:** sync script against the BookStack API; re-embed changed pages nightly
- **Tool exposure:** Home Assistant now ships an **official MCP integration** (client *and* server) — registering KB search as a tool the conversation agent can invoke is a supported path, not a hack
- **Bonus:** deploy **Open WebUI** against the LiteLLM endpoint — free RAG pipeline plus your keyboard interface to C.L.A.N.K.E.R., and it inherits the same routing policy as everything else.

---

## 5. Phase 3 — Finance

**The correction that matters: Ghostfolio is a portfolio tracker, not a budgeting tool.** It answers "how are my investments doing / what's my net worth" — holdings, allocation, performance, dividends. It cannot answer `get_spending_velocity()`, which needs transaction data.

| Question | Tool |
|---|---|
| Investments, net worth, allocation | **Ghostfolio** |
| Spending, cash flow, transaction velocity | **Firefly III** (mature API, great for tool-calling) or **Actual Budget** (nicer UX) |
| Both | Run both; expose two tool sets — they answer different questions and don't conflict |

**Ingestion (US):**
- **SimpleFIN Bridge** (~$1.50/mo) — connects US banks, has importers for both Firefly and Actual. This is allow-list hole #2.
- Or a **watched folder** for CSV/OFX exports with a cron importer — zero egress.
- **Rejected:** Nordigen/GoCardless — a cloud aggregator, mostly EU banks, not "local" in any meaningful sense.

**Tool layer:** a thin FastAPI shim translating LLM tool calls into API calls — `get_spending_velocity(timeframe="7d")` and `get_balances()` → Firefly; `get_portfolio_summary()` → Ghostfolio. Both use token auth.

---

## 6. Phase 4 — Cameras & video

- **Detection:** UniFi Protect already does person/vehicle detection on the NVR. Skip Frigate unless you need custom object classes.
- **VLM pipeline:** don't hand-write the POST script — use the **LLM Vision** custom integration (HACS). It takes a camera snapshot on trigger, sends it to any OpenAI-compatible endpoint (your Spark), and returns the description as an HA event/sensor you can speak through Piper or log. Drop-in replacement for the original Phase 4 step 2.
- **Entity control:** HA's conversation agent with Assist control enabled gives tool-calling over exposed entities (lights, switches, sensors) out of the box — pointed at LiteLLM rather than at a model server directly. Custom intents are only needed for the finance and RAG tools.

---

## 7. Phase 5 & 6 — Voice satellites and displays

### Voice hardware *(amended by §13.1 — satellite hardware conflict)*

- **Home Assistant Voice Preview Edition** (~$59, official Nabu Casa): dual mics, XMOS audio processing far better than the BOX-3, on-device microWakeWord, native ESPHome/Assist integration, 3.5mm out for wiring to a real room speaker.
- **ESP32-S3-BOX-3 is ruled out** — effectively unobtainable.
- Pi Zero 2 W + ReSpeaker still works via Wyoming, but it's fiddlier for no quality gain anymore.
- **Buy exactly one first.** Validate wake word → Whisper-on-Spark → LLM-on-Spark → Piper, measure end-to-end latency, then scale out.

### TV displays — the hidden internet dependency

Casting a Lovelace dashboard to a Chromecast/Android TV routes through HA's cast infrastructure with signed URLs, **and Google Cast devices demand internet**. That breaks on a sealed IoT VLAN.

**Local-only pattern instead — a kiosk device per TV:**
- **Fully Kiosk Browser** on an Android TV (exposes a local REST API, so HA can command it to load any dashboard URL), or a Pi/thin client running Chromium in kiosk mode
- **HDMI-CEC** to wake the TV and switch input
- `render_visual_payload(target_screen, data_type)` maps to: CEC on + tell kiosk to load URL X
- Works uniformly for finance dashboards, Grafana panels, and RTSP camera views

---

## 8. Model routing — LiteLLM as the single endpoint

### Why not the obvious options

- **Claude subscription ≠ API access.** Claude.ai, Claude Code, and the Claude API are separate products with separate billing. A Pro/Max subscription is the chat app only; HA's Anthropic integration and any tool-calling glue authenticate with an **API key** billed as pay-per-token credits from the Console. Confirm current details at `docs.claude.com` / `support.claude.com`.
- **OpenRouter** wins on flexibility (one key, one balance, OpenAI-compatible, trivial model swapping) but loses on trust surface: prompts pass through OpenRouter *and* a per-call-varying downstream provider set with heterogeneous logging/training policies. Mitigable via their prompt-logging and provider-routing controls, but the default posture is broader exposure — wrong direction for this build.

### The choice: self-hosted LiteLLM

Same payoff as OpenRouter — one OpenAI-compatible endpoint, many backends, model swap by name, unified cost tracking and fallbacks — but **you run the router**, so only vendors you explicitly call see traffic. One Docker container, same weight as Qdrant or Open WebUI, and it *simplifies* the HA side rather than adding to it.

**Model map:**

```
local/qwen3      → Spark (Ollama)        ← default, sensitive data
local/qwen-vl    → Spark (VLM)           ← camera pipeline
claude/sonnet    → Anthropic API         ← opt-in fallback
gemini/flash     → Google API            ← optional
```

OpenRouter can sit *behind* LiteLLM as one backend if you want its model breadth — but then it's an explicit per-request choice, not the default path.

Everything (HA, Open WebUI, all tool glue) points at that single URL. Per-model routing becomes just the model string.

### Two-agent setup in Home Assistant

- **`Assist (local)`** — default agent. The **only** thing that touches financial data, camera frames, personal docs, RAG content.
- **`Claude`** — named, explicitly-invoked fallback for general reasoning with no private payload (draft an email, explain a config, summarize a public article). You always know when data leaves.

**Integration note:** to point HA at a custom base URL you'll likely need the community **Extended OpenAI Conversation** integration — the stock one doesn't cleanly expose an endpoint override.

### The hard rule

> **Finance, camera, and RAG tools are pinned to `local/*` model names and can never resolve to a cloud backend.**

**And the honesty check:** if in practice you'd end up asking Claude about your spending anyway, the privacy premise is already gone — either keep everything local or drop the pretense. No wrong answer, but decide deliberately rather than by drift.

---

## 9. Resource constraints — sharing the Spark with the trading bot

*(The IBKR bot is a separate project; this section is just the shared-hardware verdict.)*

**One Spark is sufficient. Do not buy a second one as a training cluster.**

- The bot's training is **periodic LoRA, not sustained large-scale training** — a few hours, scheduled, fitting comfortably in the ~75 GB headroom.
- Clustering two Sparks yields only **~23–25 GB/s cross-node** (vs 273 GB/s local memory, 600 GB/s internal). Tensor parallelism chokes on it — reviewers benchmark under pipeline parallelism *because* TP saturates the link. The 93.5%-DDP-efficiency figures floating around mean "a model that already fits in one box, ~1.87× faster" — not a bigger model.
- Vendors and reviewers alike position the two-node config as a **dev/learning platform to prototype distributed workflows before deploying to cloud**, not to run them.
- For genuinely large training, **burst to rented cloud GPU**: H100/H200/B200 give 3+ TB/s HBM and ~900 GB/s NVLink, pay-per-run. **Public market data carries no privacy sensitivity** — positions, orders, and ledger stay local, so this costs you nothing on posture.

**Workload decomposition — only two of four jobs are real GPU consumers:**

| Job | Load |
|---|---|
| IBKR ingestion + order execution | CPU/network only, ~zero GPU |
| Signal inference | Light periodic bursts |
| Training / finetuning | **Heavy — schedule off-peak** |
| Monte Carlo / simulated returns | **Heavy if continuous — schedule off-peak** |

**Rules for coexistence:**

1. **Live IBKR gateway and order state live on the always-on NUC, not the Spark.** Never let a brokerage connection drop mid-order because the AI box is loading a new VLM. Also dodges aarch64 wheel friction (`ib_insync`, TA-Lib, backtesting libs). Clean seam: **Spark serves compute, NUC orchestrates** — same topology as LiteLLM.
2. **Cron heavy training and simulation overnight.** With no MIG, a saturated GPU means your "turn off the lights" query queues behind a training run and C.L.A.N.K.E.R. feels broken. CUDA MPS softens concurrent sharing but guarantees nothing.
3. **Use LoRA/QLoRA, not full-parameter finetuning.** Full FT of an 8B model with Adam states can consume 60–80 GB; stacked on ~40 GB of resident inference models, you brush the 128 GB ceiling. LoRA drops that to single-digit GB and lets everything stay resident.
4. **High-volume text ingestion is a bandwidth ceiling, not a memory one.** Fix it architecturally: **cascade** — cheap embedding/small-model first pass filters the firehose, the expensive LLM only runs on survivors. Orders of magnitude cheaper, and correct regardless of hardware.
5. **If contention becomes a real, measured problem** — add a second Spark as a **fully independent node** (Spark A = latency-sacred assistant; Spark B = bot compute), *never* as a cluster member.

### 9.1 Paper trading — Alpaca vs IBKR paper

Two different jobs, and they want different venues:

| Job | Venue | Why |
|---|---|---|
| **Validating strategy P&L** | **IBKR paper** | Same API, same instruments, same multi-leg support as the live venue. Paper→live transitions test nothing new. Alpaca-paper→IBKR-live means re-validating the entire execution layer at the exact moment real money enters |
| **Dev loop, CI, plumbing tests** | **Alpaca paper** | Pure REST — no IB Gateway/TWS process, no socket API, no Java, no aarch64 wheel friction. Runs anywhere, including CI and the Spark |

**The trap with any paper account:** simulated fills are optimistic, and they are *most* optimistic exactly where this strategy lives. Multi-leg options spreads have wide bid/ask spreads, and paper engines tend to fill at mid. Real credit-spread execution rarely does. Paper trading validates that the *code* works; it does not validate that the *edge* survives slippage. Treat paper P&L as an upper bound, not an estimate.

Alpaca's options support is also thinner than IBKR's, particularly for multi-leg orders — which is the whole shape of the strategy — so it is a poor proxy for execution behaviour even setting fills aside.

**Verdict:** Alpaca paper for the dev loop and integration tests, IBKR paper for anything that informs a strategy decision. Neither changes the shared-hardware verdict above: order execution is CPU/network-bound and stays on the NUC.

---

## 10. Build order

**Do not build in blueprint order.** Voice latency is the thing most likely to disappoint, so prove it before investing in anything downstream.

1. **Phase 1** — vLLM + Qwen3-30B-A3B + Wyoming faster-whisper on the Spark (§13.5)
2. **Phase 5 (partial)** — one voice satellite + HA's Ollama integration. **This proves the entire nervous system end-to-end.** Measure latency here.
3. **Phase 4** — UniFi Protect + LLM Vision
4. **Phase 2** — RAG, Qdrant, MCP tool registration
5. **Phase 3** — Firefly/Ghostfolio + FastAPI tool shim
6. **Phase 6** — TV kiosks and `render_visual_payload`

Everything after step 2 is additive tooling on a pipeline you already trust.

---

## 11. Component matrix

| Component | Implementation | Runs on |
|---|---|---|
| LLM serving | **vLLM** (SGLang challenger; llama.cpp fallback) — §13.5 | DGX Spark |
| Primary LLM | Qwen3-30B-A3B (MoE) | DGX Spark |
| VLM | Qwen2.5-VL / Gemma 3 27B | DGX Spark |
| STT | faster-whisper large-v3-turbo (Wyoming) | **DGX Spark GPU** |
| TTS | Piper | Spark or NUC |
| Embeddings | nomic-embed-text / bge-m3 | DGX Spark |
| Vector DB | Qdrant / pgvector | DGX Spark |
| Model router | **LiteLLM** (self-hosted) | NUC |
| Chat/RAG UI | Open WebUI | NUC |
| Automation hub | Home Assistant Core | NUC |
| Conversation agents | HA Ollama (local, default) + Extended OpenAI (Claude fallback) | NUC |
| Camera VLM bridge | LLM Vision (HACS) | NUC → Spark |
| Detection / NVR | UniFi Protect | UniFi hardware |
| Spending ledger | Firefly III / Actual Budget | NUC |
| Portfolio | Ghostfolio | NUC |
| Bank ingestion | SimpleFIN Bridge / watched CSV folder | NUC |
| Finance tools | FastAPI shim | NUC |
| Voice satellites | see §13.1 (Voice PE vs Waveshare 4.3C — unresolved) | Distributed, IoT VLAN |
| Displays | Fully Kiosk / Chromium kiosk + HDMI-CEC | Per-TV, IoT VLAN |
| Firewall/VLANs | UniFi Dream Machine | — |

---

## 12. Operational note

**Back up the HA config, Firefly database, Qdrant collections, and LiteLLM config to somewhere other than the Spark.** With this much bespoke glue, **the config *is* the project** — the models are re-downloadable, your integration work is not.

---

## 13. Amendments (Claude Code session, 2026-08-16)

### 13.1 Satellite hardware — open conflict to resolve

§7 settled on **HA Voice Preview Edition**, but the current stated preference is the **Waveshare ESP32-S3-Touch-LCD-4.3C** (800×480 touch, dual-mic array, ES7210 ADC + ES8311 codec, 16MB flash / 8MB PSRAM), many units, doubling as voice satellite + per-room wall panel. **ESP-VoCat** (Espressif first-party) evaluated as a third option.

| | Voice PE | Waveshare 4.3C | ESP-VoCat |
|---|---|---|---|
| Audio front end | **XMOS XU316 — hardware AEC, real barge-in** | ES7210 + ES8311, software AEC possible (§13.1a) | ES7210 + ES8311 + NS4150B, same software-AEC path |
| Speaker | 3.5mm out to a real room speaker | Weak onboard | **Built-in 3W + amp** — best standalone audio |
| Mic array | Dual, XMOS-processed | Dual | Dual + **sound-source localization** (ESP-IDF only, not exposed by ESPHome) |
| Display | None | **4.3" 800×480 touch — real dashboard** | 1.85" circular 360×360 (ST77916 QSPI) — a *face*, not a dashboard |
| SoC headroom | — | 16MB flash / 8MB PSRAM | **16MB flash / 16MB PSRAM** (unusually generous) |
| ESPHome maturity | **First-class, official** | Community configs (sibling 4.3B repo); mic+speaker share one I2S bus — known fiddly | **None known** — new board, circular QSPI LVGL work from scratch |
| Extras | — | — | Battery (3.7V LiPo), microSD, Pogopin + magnetic connector |
| Supply | Nabu Casa | Waveshare/Amazon | DigiKey + Mouser (good) |

**Revised verdict on ESP-VoCat — promoted, on a social-design argument (see §13.1b).** Initial assessment was "better hardware, wrong role," on the grounds that a 1.85" circular screen can't be a wall dashboard and the board has no ESPHome precedent. That reasoning weighed build cost and dashboard function only. It missed the **guest-legibility** requirement, which is a real design constraint and outranks both.

Standing objections, which remain true and must be designed around:
- 1.85" circular screen is a face/status display, not a dashboard — it does not replace the 4.3C's panel function.
- No ESPHome precedent: audio config *and* circular QSPI ST77916 LVGL work from scratch. Espressif's own ESP-IDF demos do full-duplex voice + animated UI on this exact board, so it is proven possible — the open question is whether ESPHome's stack can carry face + wake word + AEC concurrently. 16MB PSRAM materially helps. **Fallback if it can't: native ESP-IDF firmware speaking the ESPHome protocol** (cf. OHF-Voice/linux-voice-assistant, which reimplements that protocol outside ESPHome).
- **No physical mute switch** — confirmed absent from both the v1.2 user guide and the esp-bsp README. Controls are POWER, BOOT, RST only; one green status LED on the MicBoard. **Voice PE has a hardware mute; VoCat does not.** This directly undercuts the guest-comfort case and needs mitigation (§13.1b).

### 13.1b Social legibility as a first-class requirement

**Requirement (added 2026-08-16):** guests must be able to tell, without being told, that a device is present and whether it is listening. Ambient mics behind wall panels in every room fail this; a small, visibly device-shaped object with a face passes it.

This reframes the fleet, and the resolution is **not** one standard everywhere:

| Space | Device | Why |
|---|---|---|
| Guest-facing (living room, guest room, hallways, bath) | **ESP-VoCat** | Legible as a device; face shows listening state; socially "cute" rather than surveillant |
| Private + dashboard-wanting (kitchen, office, utility) | **Waveshare 4.3C** | Panel function earns the wall mount where guests aren't the concern |
| Wherever voice quality dominates | **Voice PE** | Hardware AEC + physical mute; keep in the mix |

**Mitigations for the missing hardware mute** (pick at least one before guests rely on it):
1. **Expose mic state on the face** — idle vs. actively-streaming must be unmistakable at a glance, not a subtle color shift. This is the cheapest and most legible affordance the board can offer.
2. **Wire a physical switch** via the I2C expansion header or Pogopin interface — the board reserves both. A real mechanical cut is the only affordance that survives a skeptical guest.
3. **Put Voice PE in the most privacy-sensitive room** (guest bedroom) specifically because it ships with a hardware mute.

**Honesty check:** a friendly face does not change what the mics do. The substantive privacy answer is the §0/§1 posture — local-only inference, sealed IoT VLAN, nothing leaving the house — and that story is what a guest should actually be told. The form factor makes the presence *honest*; it is not itself a privacy control. Don't let the cuteness substitute for the mute switch.

**Recommended resolution: buy 1× Voice PE + 1× Waveshare 4.3C + 1× ESP-VoCat and A/B all three in the noisiest room.** Cost and extra integration time are accepted. Validate far-field pickup first — a device that fails to hear you across the room is unfriendly to guests in a different and worse way.

### 13.1a AEC correction — software AEC is viable on ES7210 boards

Earlier claim ("no XMOS ⇒ no echo cancellation") was too strong. Corrected position:

- ESPHome natively supports the **ES7210** as an `audio_adc` platform, and the chip is 4-channel *specifically* so two mics plus a **speaker loopback reference** can be captured together — which is what an AEC algorithm needs.
- As of ESPHome **2026.7.0 there is still no official AEC component**, but external components exist: **`esp_audio_stack` + `esp_aec`** from the esphome-audio-stack project.
- Cost: AEC burns roughly **7ms of a 16ms frame budget** on an ESP32-S3 — real, but affordable given the S3 is doing nothing but wake word and streaming.

Consequence: both the Waveshare 4.3C and ESP-VoCat *can* reach usable barge-in, via external components rather than out of the box. Voice PE still wins on reliability (dedicated silicon, zero config, no CPU budget spent), but the gap is "extra integration work," not "impossible." Validate this in the A/B test rather than assuming either way.

### 13.2 Two-tier LLM instead of one

Qwen3-30B-A3B is the right *fast path* for voice latency, but for open-ended "showerthought" reasoning, keep a second, heavier MoE resident and route to it by name via LiteLLM:

```
local/fast   → Qwen3-30B-A3B      (voice default; /no_think for snappy replies)
local/deep   → gpt-oss-120b MXFP4 (~63 GB; MoE w/ 5.1B active — still bandwidth-viable)
```

Both fit in 128 GB alongside the rest of the §3 budget if the VLM stays at 7B (~6 GB); with a 27–32B VLM you're at the ceiling — pick two of three (deep LLM, big VLM, training headroom) or load-on-demand. Routing trigger can be explicit ("think hard about…"), a pipeline choice, or a cheap classifier later.

### 13.3 Missing subsystem: persistent memory & learning

Requirement added after the web-session doc: C.L.A.N.K.E.R must remember users/preferences/history and improve over time. Design principle: **memory layer around frozen models, not continuous weight training.**

- **Memory proxy** on the NUC, sitting between HA/Open WebUI and LiteLLM: retrieves relevant memories from Qdrant (reusing the Phase 2 embedder + vector store) and injects them into context; extracts new durable facts after exchanges.
- **Nightly reflection job**: consolidate the day's conversations into curated memories; prune contradictions.
- **HA recorder** already covers sensor/event history — that's a tool call, not a memory.
- **Periodic LoRA on the Spark** (off-peak, per §9 rules) only for persona/style — knowledge lives in retrieval.

Slot this as **Phase 2.5** in the §10 build order — it reuses Phase 2 infrastructure and pays off everywhere downstream.

### 13.4 Minor notes

- TTS: Piper to start; **Kokoro** is a meaningful voice-quality upgrade and still real-time on the Spark — revisit after latency is proven.
- Current-events gap: a self-hosted **SearXNG** instance as a search tool keeps reasoning local while fetching fresh facts — one more (optional, named) allow-list hole, better posture than routing whole conversations to a cloud model.

---

## Open items

- Resolve §13.1 satellite hardware (order 1× Voice PE + 1× Waveshare 4.3C, A/B test)
- Two-agent LiteLLM configuration (model map + HA agent wiring)
- Ghostfolio/Firefly FastAPI tool shim (schemas + endpoints)
- Memory proxy design (§13.3) — service spec + reflection job
