# Memory Subsystem

Persistent memory and personalization. Satisfies `FR-2.*`; constrained by the 50 ms retrieval budget in `LATENCY-BUDGET.md §2` and the isolation requirements in `SECURITY-MODEL.md`.

---

## 1. Position: retrieval, not continuous training

The instinctive reading of "it should learn continuously" is online weight updates. That is the wrong mechanism here, for reasons that are practical rather than philosophical:

| Approach | Fact recall | Update cost | Deletion | Auditability |
|---|---|---|---|---|
| Continuous fine-tuning | Unreliable, lossy | Hours of GPU | **Impossible** — can't unlearn a fact | None |
| Retrieval over a memory store | Exact, cited | Milliseconds | Delete a row | Full provenance |

Deletion decides it. `FR-2.4` requires that the owner can remove a memory and have it actually be gone. A fact baked into weights cannot be removed without retraining, and cannot be proven removed at all.

**The split adopted:**

- **Non-parametric (retrieval)** — everything factual. Who, what, when, preferences, history. Changes constantly, must be deletable, must be citable.
- **Parametric (periodic LoRA)** — persona and style only. How C.L.A.N.K.E.R. speaks: terseness, register, formatting habits. Diffuse properties that retrieval expresses badly and that nobody needs to delete individually.

LoRA training runs off-peak under the admission control in `LATENCY-BUDGET.md §7`, and is optional. Ship retrieval first; the system is fully functional without ever training anything.

---

## 2. Data model

```jsonc
{
  "id": "mem_01J8X...",
  "text": "Prefers the office at 21°C overnight, not 19°C",
  "embedding": [...],                  // bge-m3
  "subject": "owner:tarun",            // whose memory this is about
  "namespace": "owner:tarun",          // whose partition it lives in
  "sensitivity": "PERSONAL",           // SECURITY-MODEL §3.1
  "trust": "TRUSTED",                  // source was identified-owner speech
  "provenance": {
    "turn_id": "turn_01J8X...",
    "principal": "owner:tarun",
    "room": "office",
    "captured_at": "2026-08-14T22:31:04Z"
  },
  "confidence": 0.86,
  "supersedes": "mem_01J7Q...",        // FR-2.3 — chain, not overwrite
  "superseded_by": null,
  "last_used_at": "2026-08-16T09:12:44Z",
  "use_count": 7,
  "ttl": null                          // null = durable; set for ephemeral facts
}
```

Storage: Qdrant collection `memory`, one payload-indexed field per filterable attribute (`namespace`, `sensitivity`, `superseded_by`).

**Superseding, not overwriting** (`FR-2.3`): a changed preference writes a new row pointing at the old one. Retrieval filters `superseded_by = null`; the history remains for audit and for answering "when did I change my mind about that."

---

## 3. Read path

Runs inline on every turn. Hard budget: **50 ms p95, or return empty** (`SYSTEM-SPEC.md §5.1`). A late memory is worse than no memory, because it spends the latency budget that `LATENCY-BUDGET.md` has no slack in.

```
utterance
  → embed (bge-m3)                          ~10 ms
  → Qdrant search, filtered by namespace    ~8 ms
      + sensitivity ∈ classes_permitted
      + superseded_by = null
  → hybrid merge with BM25 lexical hits     ~5 ms
  → rerank top-20 → top-k                   ~25 ms   (optional; drop if over budget)
  → token-budget truncation (default 512)   ~1 ms
  → return fragments + effective_class
```

**Design constraints:**

- **Namespace filter is applied in the query, not after.** Post-filtering leaks through result counts and is a bug waiting to happen.
- **Token budget is a hard cap.** Injected memories land at the *end* of the prompt so they never invalidate the prefix cache (`LATENCY-BUDGET.md §4`). Every injected token is prefill time; 512 is a starting point to be tuned against measured answer quality, not a fixed truth.
- **The reranker is the first thing cut** if the budget is missed. It improves precision but is the largest single term.

---

## 4. Multi-occupant isolation

A house is not a single-user machine. Several people speak to the same satellites, and guests speak to them too. Getting this wrong means reciting one person's private notes to another, which is the most likely way this system embarrasses its owner.

### 4.1 Principal resolution

```
utterance → speaker identification → principal
                    ↓ no match
                  guest
```

Speaker identification (`FR-1.6`) uses voice embeddings from explicit enrolment. Unidentified speech resolves to `guest` — a **fail-safe default**, not an error.

### 4.2 Namespace access matrix

| Principal | `owner:*` own | `owner:*` other | `household` | Write |
|---|---|---|---|---|
| `owner:tarun` | read/write | **no** | read/write | yes |
| `owner:other` | — | read/write own | read/write | yes |
| `guest` | **no** | **no** | **read only** | **no** |
| `system` | no | no | read/write | yes |

`guest` sessions additionally have `classes_permitted = [HOUSEHOLD]`, so no personal or financial fragment can be retrieved even by namespace confusion. Two independent controls, deliberately redundant.

### 4.3 Guest mode

Entered automatically on unidentified speech, or manually. While active:

- No personal or financial retrieval
- **No memory writes at all** — a guest's utterances are never learned from
- Tier-2 actuators unavailable (`SECURITY-MODEL.md §5`)
- **Visibly indicated on the satellite** — the state is legible without asking (`FR-1.7`)

The visible indicator is not decoration. It is the affordance that makes the privacy posture checkable by the person it protects.

### 4.4 Attribution ambiguity

Two people in a room, one speaks. Speaker ID returns 0.6 confidence for the owner. Options: treat as owner (risks cross-user leakage), treat as guest (degrades experience), or ask.

**Policy:** below the `FR-1.6` confidence threshold, resolve to `guest` and proceed. Do not ask — a system that interrogates people about who they are before answering is worse than one that occasionally under-personalizes. Never resolve ambiguity toward *more* access.

---

## 5. Write path

Runs **after** the response is delivered. Never on the critical path.

```
completed turn
  → extraction pass (small model, batched)
      "what durable facts, if any, does this exchange establish?"
  → candidate facts, each with confidence
  → drop if confidence < threshold
  → dedup: embed, search own namespace, skip if cosine > 0.95
  → contradiction check: if semantically opposed to an existing fact,
      write new + set supersedes/superseded_by
  → store with full provenance
```

**Rules:**

- **Guests never write** (§4.2).
- **Extraction is conservative.** A memory store full of "user said hello" is worse than an empty one — it dilutes retrieval and burns the token budget. Bias hard toward precision.
- **Everything is attributable** (`FR-2.5`). A memory whose origin cannot be shown is a memory that cannot be trusted or contested.

---

## 6. Reflection

A nightly batch job, admission-controlled like any other background GPU work.

| Task | Purpose |
|---|---|
| Consolidation | Merge near-duplicate memories accumulated across turns |
| Contradiction sweep | Resolve conflicting facts missed at write time |
| Decay | Demote memories with low `use_count` and old `last_used_at`; expire `ttl` rows |
| Summarization | Compress long episodic runs into durable semantic facts |

Decay is what keeps retrieval quality from degrading as the store grows. A memory system that only accumulates gets monotonically worse at finding anything.

**Reflection must never delete without trace.** Demoted and expired memories move to a cold partition, not oblivion — `FR-2.4` gives the owner deletion authority, and the reflection job should not silently exercise it.

---

## 7. Failure modes

| Failure | Behaviour | Requirement |
|---|---|---|
| Qdrant unavailable | Return empty fragments; assistant answers without memory | Voice path must not hard-fail on memory loss |
| Retrieval exceeds 50 ms | Return whatever is ready, or empty | `SYSTEM-SPEC.md §5.1` |
| Embedding model unavailable | Fall back to lexical BM25 only | Degraded, not broken |
| Extraction model unavailable | Queue turns for later extraction | Write path is async; backlog is acceptable |
| Speaker ID unavailable | All speech resolves to `guest` | Fail-safe: degrade to less access, never more |
| Memory store corrupted | Restore from backup (`OPERATIONS.md §5`) | Memory is the one component whose loss is not recoverable by re-derivation |

That last row deserves emphasis: models are re-downloadable and configs are in git, but **accumulated memory is the only irreplaceable state in the system.** Back it up accordingly.

---

## 8. Open items

| # | Item | Blocks |
|---|---|---|
| 1 | Speaker ID approach: voice embedding model, enrolment UX, confidence threshold calibration | `FR-1.6`, §4.1 |
| 2 | Extraction prompt and confidence threshold — needs tuning against a real transcript corpus | §5 |
| 3 | Decay function parameters | §6 |
| 4 | Whether the reranker fits the 50 ms budget on real hardware | §3 |
| 5 | Persona LoRA: whether it is worth doing at all, evaluated after retrieval ships | §1 |
