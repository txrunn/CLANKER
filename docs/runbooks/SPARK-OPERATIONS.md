# Runbook: operating the Spark

Day-2 procedures for the compute host. Design: [`../INFRASTRUCTURE.md`](../INFRASTRUCTURE.md). Models: [`../MODEL-CATALOG.md`](../MODEL-CATALOG.md).

All commands run from the repo root on the operator workstation unless shown with `ssh`. `tenantctl` runs on the Spark (`sudo tenantctl <tenant> status|systemctl|logs|podman`).

---

## Start or stop an on-demand model

```bash
just model up llm-deep
just model status llm-deep
just model down llm-deep
```

Before starting `local/deep`, confirm no LoRA job is running: resident set + deep + training does not fit (`MODEL-CATALOG.md §5`).

## Rotate an API key

1. Replace the value in `.env` (`openssl rand -hex 32`).
2. `just converge --tags inference,clanker`. The secret is replaced only if its hash changed; dependent services restart; consuming tenants' `endpoints.env` files are rewritten.
3. Update the key in LiteLLM on the NUC.

## Change or add a model

Follow the promotion steps in [`MODEL-CATALOG.md §6`](../MODEL-CATALOG.md#6-pinning-and-promotion). In short: edit `infra/catalog/models.yaml` → `just pin-models <key>` → `just plan` → `just pull` → `just apply` → `just smoke`.

## Roll back a model

The previous revision is still on disk (until pruned).

1. Set `revision` back to the previous SHA in `models.yaml` (`git log -p infra/catalog/models.yaml` shows it).
2. `just apply`. No pull needed.

## Prune old weights

On the Spark, list revisions not referenced by the catalog:

```bash
ssh "$TF_VAR_admin_user@$TF_VAR_spark_host" 'sudo ls -1 /srv/inference/models/*/'
```

Delete superseded revision directories older than a week with `sudo rm -rf /srv/inference/models/<key>/<old-sha>`. Never delete the pinned revision.

## Add a tenant

For another project that runs 24/7 on the Spark:

1. Add it to `infra/catalog/tenants.yaml` with an unused `uid` (2104, 2105, …) and its weights. Never reuse or renumber a uid.
2. If it calls the models, add it to the relevant models' `consumers` so it gets `/srv/<tenant>/.config/inference/endpoints.env`.
3. If it publishes ports, list them under `ports:` for the tenant, so ingress filtering covers them and Terraform rejects collisions.
4. `just plan && just apply`.

The tenant gets an account with no login, a private rootless Podman store, a lingering systemd user manager, `/srv/<tenant>`, and LAN-only egress. Its own services are Quadlet files in `/srv/<tenant>/.config/containers/systemd/`, deployed by a role for that project.

## Detect drift

```bash
just drift                   # exit 0: matches; exit 2: something would change
```

Safe to run on a schedule. A non-zero exit means someone changed the host outside the repo; `just converge` restores it.

## Audit egress

```bash
ssh "$TF_VAR_admin_user@$TF_VAR_spark_host" \
  "sudo journalctl -k --since -24h | grep -E 'spark-(egress-drop|ingress-drop|pull-)'"
ssh "$TF_VAR_admin_user@$TF_VAR_spark_host" "sudo nft list table inet spark_tenant_policy"
```

`spark-pull-*` lines should appear only during `just pull`. Any `spark-egress-drop` is a tenant trying to reach the WAN: find out why (`SEC-10`).

## Driver upgrade

The NVIDIA driver and container toolkit are held so routine updates cannot change the CUDA stack under pinned images.

1. Read the DGX OS release notes for the new driver; check the pinned vLLM image supports it.
2. `ssh … sudo apt-mark unhold <packages>`, upgrade, reboot.
3. Regenerate CDI: `ssh … sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`.
4. `just converge` (re-holds the new versions; re-runs the rootless GPU smoke test).
5. `just smoke`, then the latency benchmark from `TEST-PLAN.md`.

## Backups

Not yet automated (`OPERATIONS.md §5`). Until the restic job exists: snapshot Qdrant (`POST /collections/<name>/snapshots`), and copy `/srv/clanker/data/qdrant/snapshots/` to the NAS. The `memory` collection is irreplaceable.

## NVIDIA Sync

Optional shortcuts on your laptop. Sync's custom apps forward a local port to the same port on the Spark over SSH and run a launch script as your admin user. There is no import format, so add each one by hand.

`just outputs` prints the list (`nvidia_sync_apps`). For each: Sync → your Spark → **Custom** → **Add New**:

| Name | Port | Auto open path | Launch Script |
|---|---|---|---|
| Inference local/fast | 8000 | `docs` | contents of [`infra/nvidia-sync/inference-model.sh`](../../infra/nvidia-sync/inference-model.sh) with `PORT=8000` |
| Inference local/vision | 8002 | `docs` | same script, `PORT=8002` |
| Qdrant dashboard | 6333 | `dashboard` | [`infra/nvidia-sync/qdrant.sh`](../../infra/nvidia-sync/qdrant.sh) |
| Spark tenants | any free port (e.g. 18999) | — (check **Launch in Terminal**) | [`infra/nvidia-sync/tenant-status.sh`](../../infra/nvidia-sync/tenant-status.sh) |

The API docs page needs the inference key for "Try it out"; Qdrant's dashboard asks for its key. Closing an app in Sync only closes the tunnel; services keep running. Ports forwarded by Sync must be free on your laptop.

## Troubleshooting

| Symptom | Check |
|---|---|
| Converge fails at "GPU smoke test" | `ssh … sudo nvidia-ctk cdi list` shows `nvidia.com/gpu=all`; `ls -l /dev/nvidia*` are readable; Podman ≥ 4.x supports CDI. As `svc-inference`: `sudo tenantctl inference podman run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi <image> -L` |
| Model unit restarts in a loop | `sudo tenantctl inference logs inference-<key>`. Common: a `[verify]` flag unsupported by the pinned vLLM; `gpu_memory_utilization` larger than what is free; read-only root filesystem (set `read_only: false` on that model) |
| Endpoint unreachable from the NUC | NUC address missing from `TF_VAR_client_cidrs`; `spark-ingress-drop` in the kernel log |
| `just pull` hangs or fails on downloads | Gateway still blocks the Spark; `spark-egress-drop` lines mean the window was not open for that tenant |
| `just apply` errors about sudo | Set `ANSIBLE_BECOME_PASSWORD_FILE`, or run `just converge` to be prompted |
| Plan fails with a precondition | The message names the rule. Usually: unpinned entry (`just pin`), port clash, or budget. |
