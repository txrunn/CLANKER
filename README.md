# C.L.A.N.K.E.R.

A local-first, multi-room conversational home assistant with persistent memory, multimodal perception, and enforced data-egress boundaries — all inference on owner-controlled hardware.

**Status:** design phase. Nothing built yet. Every performance figure in these documents is an estimate or a target, not a measurement, and is labelled as such.

---

## Documents

| Doc | Contents |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Build guide. Hardware, network topology, service placement, phased rollout, settled decisions and their rationale. |
| [`docs/SYSTEM-SPEC.md`](docs/SYSTEM-SPEC.md) | Requirement register with traceable IDs, system model, complete software component inventory with interface contracts. |
| [`docs/LATENCY-BUDGET.md`](docs/LATENCY-BUDGET.md) | Stage-by-stage response-time budget, roofline analysis driving model selection, and the GPU-contention problem. |
| [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md) | Threat model, data-class lattice, information-flow enforcement, physical-world prompt injection, actuator authorization. |
| [`docs/MEMORY-SUBSYSTEM.md`](docs/MEMORY-SUBSYSTEM.md) | Persistent memory design, parametric/non-parametric split, multi-occupant isolation and guest handling. |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | SLOs, observability, failure modes and degradation paths, model lifecycle, backup and restore. |
| [`docs/TEST-PLAN.md`](docs/TEST-PLAN.md) | Acceptance criteria per phase. What "done" means for each component before the next one starts. |

**Reading order** — building: `ARCHITECTURE.md` → `SYSTEM-SPEC.md` → `LATENCY-BUDGET.md`. Reviewing: `SYSTEM-SPEC.md` → `SECURITY-MODEL.md` → `OPERATIONS.md`.

## Hardware

| Tier | Machine | Role |
|---|---|---|
| Compute | NVIDIA DGX Spark (GB10), 128 GB unified LPDDR5X @ ~273 GB/s | All model inference and training |
| Orchestration | Always-on homelab NUC | Home Assistant, model router, tool services, storage, observability |
| Edge | ESP32-S3 voice satellites, one per room | Wake word, audio I/O, local UI |
| Network | UniFi Dream Machine | VLAN segmentation, default-deny egress |

Two hardware facts drive most of the design: the accelerator is **capacity-rich but bandwidth-poor**, and it has **no MIG partitioning**, so a latency-critical voice path and heavy batch jobs share one indivisible GPU. See [`docs/LATENCY-BUDGET.md`](docs/LATENCY-BUDGET.md).

## Design commitments

These are load-bearing. Changing one invalidates analysis elsewhere.

1. **Inference for private data never leaves the house.** Cloud backends exist only for an explicitly-invoked, non-sensitive agent. Enforced at the router, not by convention — see `SEC-1`.
2. **The NUC is the availability tier; the Spark is the compute tier.** Home Assistant must keep working when the Spark is rebooting, loading a model, or out of memory. Voice degrades to local intent matching rather than failing.
3. **Latency is a hard requirement, not a nice-to-have.** A voice assistant that answers correctly in four seconds is a failed voice assistant. Budget in `NFR-1`.
4. **Untrusted input never reaches an actuator unmediated.** Camera frames, RAG documents, and guest speech are data, never instructions. See `SEC-2`.
5. **Satellites are legible.** A person in the room can tell a device is present and whether it is listening, without being told.

## Conventions

- Requirement IDs (`FR-*`, `NFR-*`, `SEC-*`, `OPS-*`) are stable and cross-referenced. Don't renumber.
- Figures not marked **[measured]** are estimates. Replace with measurements as the testbed comes up, and change the label.
- **[verify]** marks a claim resting on vendor documentation or secondhand benchmarks that should be confirmed on the actual hardware before it is depended upon.

## License

[AGPL-3.0](LICENSE).

## A note on publishing

This repo describes the design of a system that secures a home. That is deliberate — a security design that only works while secret is not a security design, and this one is meant to survive being read.

What must never be committed here: real VLAN IDs, addresses, credentials, which rooms have satellites, or the chosen posture setting from `docs/SECURITY-MODEL.md §5.4`. Instance configuration belongs in a private repo. This one holds the design.
