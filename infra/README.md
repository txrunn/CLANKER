# infra/

The compute host (DGX Spark) as code. Terraform validates and renders the desired state; Ansible applies it; Hermit and uv pin the tools.

| Start here | |
|---|---|
| First install | [`docs/runbooks/SPARK-BOOTSTRAP.md`](../docs/runbooks/SPARK-BOOTSTRAP.md) |
| Day-2 operations | [`docs/runbooks/SPARK-OPERATIONS.md`](../docs/runbooks/SPARK-OPERATIONS.md) |
| Design and rationale | [`docs/INFRASTRUCTURE.md`](../docs/INFRASTRUCTURE.md) |
| Models and memory budget | [`docs/MODEL-CATALOG.md`](../docs/MODEL-CATALOG.md) |

```
catalog/      tenants.yaml, models.yaml, images.yaml — what runs (committed, instance-free)
terraform/    modules/spark-host (contract) + envs/prd (root)
ansible/      playbooks/{site,pull}.yml + roles/
scripts/      pin-images.sh, pin-models.sh, smoke.sh
nvidia-sync/  optional NVIDIA Sync custom-app scripts
.generated/   rendered inventory + host vars (gitignored)
```

Everything identifying a specific house (hostname, admin user, addresses, keys) lives in the operator's `.env`, never here. `just` lists every task.
