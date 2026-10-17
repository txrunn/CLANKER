# Infrastructure

How the compute host (the DGX Spark) is defined as code: what owns what, how it is isolated, and how it is reproduced on another Spark. Model choices are in [`MODEL-CATALOG.md`](MODEL-CATALOG.md); step-by-step procedures are in [`runbooks/`](runbooks/).

**Scope.** The compute tier only (`SYSTEM-SPEC.md §1.1`). The NUC, the UniFi gateway, and the satellites are not yet in code. The NUC is the natural next `infra/terraform/modules/` entry; UniFi VLANs and egress holes (`SEC-4`, `SEC-10`) are the one part of this house with a real API, and the best fit for Terraform-native resources when they are added.

**Status.** Written and statically validated; not yet applied to hardware. Items marked **[verify]** must be confirmed on the Spark before they are depended upon (see §12).

---

## 1. Requirements this implements

| Requirement | How |
|---|---|
| `NFR-4.1` All config in version control | Every host change is a role, template, or catalog entry. Nothing is configured by hand. |
| `NFR-4.2` Redeployable from repo + backups | `just plan && just pull && just apply` on a fresh Spark, then restore Qdrant snapshots. §9 |
| `NFR-4.3`, `SEC-7` Pinned by digest | Images by `sha256` digest, models by 40-hex commit. Terraform refuses to plan otherwise. §8 |
| `NFR-2.4` Restart one service at a time | Each model and service is its own systemd unit. |
| `NFR-3.2` Training headroom | GPU memory is budgeted per model; Terraform rejects a catalog over budget. |
| `SEC-8` Service-to-service auth | Every endpoint requires an API key; the LAN is not trusted. §7 |
| `SEC-9` No plaintext secrets in the repo | Secrets live only in the operator's `.env` and the host's Podman secret store. §7 |
| `SEC-10` Egress is auditable | Per-tenant nftables egress policy with logging; the pull window is explicit and self-closing. §5 |
| Least privilege; other 24/7 projects share the box | One unprivileged account per project ("tenant"), rootless containers, no shared daemon. §4 |

---

## 2. Toolchain and why it is split

```
.env (instance + secrets) ──► Terraform ──► validated, rendered inputs ──► Ansible ──► the Spark
infra/catalog/*.yaml ──────────┘   (plan shows the diff)                    (only thing that touches the host)
```

**Terraform is the contract.** It reads the catalog and the instance values, enforces invariants (pinning, port collisions, memory budget, tenant integrity, derivative-model gate), shows the diff in `plan`, renders the inventory and host variables, and triggers a converge when they or the roles change. Its state holds no secrets.

**Ansible is the engine.** A Linux box has no API for Terraform to manage; doing it with Terraform provisioners would mean SSH scripts with no idempotency and no drift detection, which HashiCorp itself calls a last resort. Ansible is idempotent, can run in check mode (`just drift`), and is the standard tool for configuring existing hosts.

**Rejected alternatives**

| Option | Why not |
|---|---|
| Terraform only (provisioners) | Not idempotent, no drift detection, plan cannot show host-level changes. |
| Ansible only | Works, but loses the typed contract and plan-time validation; also the natural home for future API-backed resources (UniFi, NUC). |
| NixOS / nix-darwin style | DGX OS owns the NVIDIA driver and CUDA stack; replacing the OS costs more than it saves. |
| Docker | Anyone in the `docker` group is effectively root. Rootless Podman has no daemon and runs each tenant's containers as that tenant. |
| `ansible/ansible` Terraform provider | Stores playbook output in state and re-runs on fuzzy triggers. A `terraform_data` + `local-exec` with explicit content hashes is clearer. |

**Pinned tooling.** [Hermit](https://github.com/cashapp/hermit) pins every binary (`bin/`): Terraform 1.16.5, just, uv, tflint, yq, jq, crane, shellcheck, gitleaks. `uv` pins the Python tools (`ansible-core 2.21.5`, `ansible-lint`, `yamllint`) in `pyproject.toml` + `uv.lock`. The justfile puts both on `PATH`, so nothing has to be installed globally and two operators get identical tools. Hermit's shell hook puts `bin/` on `PATH` while you are inside the repo, which is what lets the docs say `just` rather than `bin/just`.

---

## 3. Repository layout

```
bin/                         Hermit: pinned operator binaries (download on first use)
justfile                     every operator task (`just` lists them)
.env.example                 instance values + secret slots; copy with `just env`
pyproject.toml, uv.lock      pinned Ansible tooling
.githooks/pre-commit         blocks .env, rendered inputs, state; runs gitleaks
infra/
  catalog/
    tenants.yaml             projects on the host: uid, weights, GPU use
    models.yaml              what the inference tenant serves (MODEL-CATALOG.md)
    images.yaml              container images, digest-pinned
  terraform/
    modules/spark-host/      the contract: validation, rendering, converge trigger
    envs/prd/                root module for the production Spark
  ansible/
    playbooks/site.yml       converge
    playbooks/pull.yml       egress window + fetch images and weights
    playbooks/spotcheck.yml  self-cleaning hardware check (no Terraform needed)
    playbooks/teardown.yml   inverse of site.yml; each role owns tasks/teardown.yml
    roles/
      host_base/             packages, NVIDIA holds, sshd hardening, tenantctl
      container_runtime/     rootless Podman, CDI GPU spec, registry policy
      tenant/                svc-<name> accounts, subids, linger, CPU/IO weight
      host_firewall/         per-tenant nftables ingress/egress policy
      inference_platform/    one vLLM unit per model, API key, consumer env files
      model_store/           pinned weight downloads (pull window only)
      clanker_services/      Qdrant (memory service and STT later)
  scripts/                   pin-images, pin-models, smoke
  nvidia-sync/               NVIDIA Sync custom-app launch scripts
  .generated/<env>/          rendered inventory + host vars (gitignored)
```

---

## 4. Tenancy

A **tenant** is one project that runs 24/7 on the Spark. Defined in [`infra/catalog/tenants.yaml`](../infra/catalog/tenants.yaml).

| Tenant | Account | UID | Owns | GPU |
|---|---|---|---|---|
| `inference` | `svc-inference` | 2101 | All vLLM processes; one copy of each model | yes |
| `clanker` | `svc-clanker` | 2102 | Qdrant; later the memory service and GPU STT | no |
| `stratum` | `svc-stratum` | 2103 | stratum / mLLM batch labelling and LoRA training | training |

Each tenant gets:

- **An account that cannot log in.** Shell `/usr/sbin/nologin`, password locked, no groups beyond its own, not in `sudo`. SSH is restricted to the admin user (`AllowUsers`).
- **Its own rootless container runtime.** Podman with a private image store under `/srv/<tenant>`, subordinate IDs `uid × 65536` (stable across rebuilds), its own systemd user manager kept alive with `loginctl enable-linger`.
- **One writable tree:** `/srv/<tenant>` (mode `0750`), which is also its home.
- **A CPU/IO weight** on its `user-<uid>.slice` (inference 400, clanker 200, stratum 50), so batch work yields CPU to the voice path. Memory is not capped by cgroup: on GB10 unified memory, GPU allocations are not reliably charged to the cgroup, so a `MemoryMax` would cap the wrong thing. GPU memory is budgeted per model instead (`MODEL-CATALOG.md §3`).
- **An egress policy keyed on its UID** (§5).

**Why one inference tenant instead of each project running its own models.** 128 GB cannot hold two copies of a 63 GB model. Models are loaded once by `svc-inference` and called by other tenants over HTTP with an API key, with vLLM priority scheduling deciding who waits (`MODEL-CATALOG.md §4`).

**Operating a tenant** without logging in as it: `sudo tenantctl <tenant> status | systemctl … | logs [unit] | podman …` (installed by `host_base`). Adding a tenant: [`runbooks/SPARK-OPERATIONS.md`](runbooks/SPARK-OPERATIONS.md#add-a-tenant).

### Naming conventions

| Thing | Pattern | Example |
|---|---|---|
| Tenant account / group | `svc-<tenant>` | `svc-inference` |
| Tenant data root | `/srv/<tenant>` | `/srv/clanker/data/qdrant` |
| Container and unit | `<tenant>-<component>` | `inference-llm-fast`, `clanker-qdrant` |
| Model alias (API name) | `local/<role>` | `local/fast`, `local/deep` |
| Catalog key | `<role>[-variant]` | `llm-fast`, `llm-fast-fallback` |
| Weights on disk | `/srv/inference/models/<key>/<revision>/` | revision is the full commit SHA |
| Podman secret | `<purpose>-api-key` | `inference-api-key` |
| nftables table | `inet spark_tenant_policy` | sets `pull_<tenant>`, `lan_v4` |
| Terraform | dirs `kebab-case`, resources `snake_case`, env roots `prd`/`stg`/`dev`/`lab` | `modules/spark-host`, `terraform_data.catalog` |
| Ansible | role-prefixed variables; host inputs prefixed `spark_` | `inference_platform_home`, `spark_models` |

---

## 5. Network policy

Implemented as its own nftables table, `inet spark_tenant_policy`, loaded by `spark-tenant-policy.service`. It never flushes the ruleset, so DGX OS and other tools keep their own tables; replacing it is atomic.

**Ingress.** Only the ports tenants publish are filtered. Those accept loopback (including NVIDIA Sync's SSH tunnels) and `client_cidrs` (the NUC and the admin workstation), and drop everything else with a rate-limited `spark-ingress-drop` log. Other host ports (SSH, DGX dashboard) are untouched.

**Egress.** Traffic from tenant UIDs may reach loopback and `lan_cidrs` only. Everything else is rejected with a `spark-egress-drop` log line. This works for containers because rootless Podman networking (pasta) opens sockets as the tenant user, so `meta skuid` matches every container a tenant runs.

**The pull window** is ARCHITECTURE.md §1 WAN hole #4 ("manual model pulls"), made mechanical. `just pull` adds `443 timeout 120m` to the `pull_<tenant>` set for the tenants that fetch, runs the downloads, and deletes the element in an `always` block. If the operator's machine dies mid-pull, the element expires on its own. Every allowed connection is logged as `spark-pull-<tenant>`.

**Relationship to the UniFi gateway.** This is defense in depth, not a replacement. The gateway's server-VLAN default-deny still governs the host as a whole; this table additionally stops one tenant from reaching the WAN while the gateway hole is open for another, and stops containers from calling out even if the gateway is misconfigured. Host-level traffic from root (apt, NVIDIA updates) is not filtered here; the gateway governs it.

---

## 6. Containers

- **Runtime:** rootless Podman, no daemon. Services are [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) files in `~/.config/containers/systemd/`, generated into systemd user units.
- **GPU:** CDI (`AddDevice=nvidia.com/gpu=all`). DGX OS's `nvidia-cdi-refresh` writes `/var/run/cdi/nvidia.yaml` as CDI spec 0.7.0, whose `additionalGids` field Ubuntu 24.04's Podman 4.9 cannot parse, so Podman discards the file and the GPU is "unresolvable" **[measured]**. The converge therefore keeps a copy at `/etc/cdi/nvidia-podman.json`: `spark-cdi-compat` regenerates it with `nvidia-ctk`, drops `additionalGids` (the device nodes are `0666` on GB10, so nothing is lost) and labels it 0.6.0, and a drop-in on `nvidia-cdi-refresh.service` reruns it whenever DGX OS regenerates its own spec. CDI ranks `/etc/cdi` below `/var/run/cdi`, so a future Podman that reads the original uses it and the copy is inert; turn it off then with `just converge -e spark_cdi_compat=false`. The converge ends with `nvidia-smi -L` inside a rootless container as `svc-inference`, the only check that tests what Podman sees.
- **Hardening per container:** `NoNewPrivileges`, `DropCapability=ALL`, read-only root filesystem with a tmpfs `/tmp` (vLLM; per-model opt-out with `read_only: false`), weights mounted read-only, writable caches on a dedicated volume.
- **No runtime pulls:** `pull_policy = "never"` host-wide and `--pull=never` per unit. A service can only run an image `just pull` fetched while the window was open.
- **Fully qualified names only:** `short-name-mode = "enforcing"` with no search registries.
- **Logs:** journald, readable with `sudo tenantctl <tenant> logs <unit>`.

---

## 7. Secrets

| Secret | Lives in | Reaches the host as | Rotated by |
|---|---|---|---|
| `CLANKER_INFERENCE_API_KEY` | operator `.env` | Podman secret `inference-api-key` → `VLLM_API_KEY`; `endpoints.env` (0600) for consuming tenants | edit `.env`, `just converge` |
| `CLANKER_QDRANT_API_KEY` | operator `.env` | Podman secret `qdrant-api-key` → `QDRANT__SERVICE__API_KEY` | same |
| `HF_TOKEN` (optional) | operator `.env` | process environment during `just pull` only | — |
| sudo password (optional) | file named by `ANSIBLE_BECOME_PASSWORD_FILE`, outside the repo | never | — |

Secrets flow from the environment straight to Ansible (`lookup('env')`) and never pass through Terraform, so state is safe to keep unencrypted. Podman secrets carry a `sha256` label of their value; Ansible replaces one only when the key changes, then restarts what uses it. All tasks that touch secret values are `no_log`.

**Tradeoff:** one inference key is shared by all consumers. vLLM accepts a single key; per-tenant keys and per-tenant priority enforcement belong in a gateway (LiteLLM on the NUC for C.L.A.N.K.E.R. callers). On-host tenants are additionally separated by UID.

---

## 8. Pinning and reproducibility

| Layer | Pinned by | Updated with |
|---|---|---|
| Operator binaries | Hermit package versions in `bin/` | `bin/hermit upgrade <pkg>` |
| Python tooling | `uv.lock` | `uv lock --upgrade-package <pkg>` |
| Terraform providers | `.terraform.lock.hcl` (created by first `just init`; commit it) | `terraform init -upgrade` |
| Container images | `sha256` digest of the `linux/arm64` manifest | `just pin-images --refresh` |
| Model weights | Hugging Face commit SHA | `just pin-models <key>` |
| NVIDIA driver + toolkit | `apt-mark hold` | [driver upgrade runbook](runbooks/SPARK-OPERATIONS.md#driver-upgrade) |

**Reusing this on another Spark.** Nothing in the repo names a specific house. Clone, install the Hermit shell hook (`bin/hermit shell-hooks --bash`), `just bootstrap`, `just env`, set the `TF_VAR_*` values for your host and LAN, then follow [`runbooks/SPARK-BOOTSTRAP.md`](runbooks/SPARK-BOOTSTRAP.md). Tenants, models, and ports come from the catalog; edit it in a fork if your mix differs.

**What code cannot recreate:** Qdrant collections (the `memory` collection is irreplaceable, `OPERATIONS.md §5.1`) and any LoRA adapters. Those are backed up to the NAS; restore is part of `NFR-4.2`.

---

## 9. Lifecycle

| Command | Does | Touches host |
|---|---|---|
| `just plan` | Validate the catalog and instance inputs; show the diff | no |
| `just render` | Write the Ansible inputs without converging (first install) | no |
| `just apply` | Render inventory/vars; converge if anything changed | yes |
| `just converge` | Run the converge now (prompts for sudo if no password file) | yes |
| `just drift` | Converge in check mode; exit 2 if anything would change | no |
| `just pull` | Open the egress window, fetch pinned images and weights, close it | yes (downloads only) |
| `just spotcheck` | Throwaway tenant proves rootless GPU, pasta UID and Quadlet keys, then removes itself | yes (leaves nothing) |
| `just smoke` | Auth, endpoint, and revision checks from the workstation | no |
| `just model up\|down\|status <key>` | Start or stop an on-demand model | yes |
| `just teardown` | Remove everything converge created; `/srv/<tenant>` kept unless `-e purge=true` | yes |
| `just lint` | fmt, validate, tflint, ansible-lint, yamllint, shellcheck, gitleaks | no |

Terraform only converges when inputs or roles change. Drift that happens on the host without an input change (someone edits a file) is caught by `just drift`, which is safe to run on a schedule.

---

## 10. NVIDIA Sync

Optional convenience, not part of the system. Sync's custom apps forward a local port to the Spark over SSH and run a launch script as the admin user; there is no import format, so the entries are printed by `just outputs` (`nvidia_sync_apps`) and the scripts live in [`infra/nvidia-sync/`](../infra/nvidia-sync/). The scripts only check health and hold the tunnel; closing an app never stops a service. Setup: [`runbooks/SPARK-OPERATIONS.md#nvidia-sync`](runbooks/SPARK-OPERATIONS.md#nvidia-sync).

---

## 11. Residual risks and known limits

| Risk / limit | Why accepted, or what would fix it |
|---|---|
| Any local account can open `/dev/nvidia*` (DGX OS default mode `0666`) | Restricting device nodes needs driver module options and a reboot, and could break DGX OS services. Tenants other than GPU ones simply do not request the device. Revisit if an untrusted tenant is ever added. |
| Tenants may reach the whole LAN | Needed for the NUC, NAS, and DNS. Narrow `lan_cidrs` per deployment if the LAN holds anything sensitive. |
| One shared inference API key | vLLM limitation (§7). Gateway-level keys are the fix. |
| GPU memory is not enforced by the kernel | Budgeted in the catalog and checked at plan time; a misbehaving process can still exceed its share. vLLM's own `--gpu-memory-utilization` is the runtime bound. |
| `terraform apply` converges only on change | `just drift` closes the gap. |
| First converge needs host package egress | `apt` runs as root and is governed by the gateway, not this table. Open the gateway's server-VLAN hole for the bootstrap run. |

---

## 12. Hardware verification checklist

Before relying on this, confirm on the Spark and change **[verify]** labels to **[measured]**. `just spotcheck` answers items 1-3 in a few minutes before anything is installed for real, and removes everything it creates; the converge re-checks item 1 as `svc-inference`.

1. Rootless CDI works: the converge's `nvidia-smi -L` step passes as `svc-inference`.
2. pasta preserves the tenant UID: from a `svc-clanker` container, `curl https://example.com` is rejected and logged as `spark-egress-drop`; during `just pull` it succeeds for `svc-inference` only.
3. Quadlet keys used here are supported by the installed Podman (`podman --version`; `HealthStartPeriod`, `ReadOnly`, `AddDevice`).
4. The vLLM image tag and the per-model flags in `models.yaml` start cleanly (each **[verify]** there).
5. Measured `gpu_memory_utilization` per model matches the catalog; peak stays under budget with `local/deep` up.
6. Prefix-cache hit ratio on the voice prompt for `local/fast` (`MODEL-CATALOG.md §7`).
7. A second `just converge` reports `changed=0`.
