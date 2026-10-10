# Runbook: bootstrap a Spark

From a factory-fresh DGX Spark to a converged compute host. Design: [`../INFRASTRUCTURE.md`](../INFRASTRUCTURE.md). Expect 1-2 hours, most of it downloading weights.

## Prerequisites

- DGX OS first-boot setup done; you have an admin account with sudo (e.g. the one NVIDIA Sync uses).
- The Spark has a stable address on the server VLAN (DHCP reservation) and is reachable by name or IP from your workstation.
- Your workstation: Linux or macOS with `git`, `bash`, `ssh`, `curl`, `openssl`. Everything else comes from Hermit and uv.
- For the bootstrap run only: the gateway allows the Spark to reach the internet (apt packages, image registry, Hugging Face). Close it again afterwards (`ARCHITECTURE.md §1`).

## 1. Workstation tooling

```bash
git clone https://github.com/txrunn/CLANKER && cd CLANKER
. bin/activate-hermit        # optional; the justfile works without it
just bootstrap               # uv sync --frozen; enables .githooks
```

## 2. Instance configuration

```bash
just env                     # writes .env (0600) with fresh API keys
$EDITOR .env
```

Set at least:

| Variable | Example | Notes |
|---|---|---|
| `TF_VAR_spark_host` | `spark.local` | hostname or IP |
| `TF_VAR_admin_user` | your admin account | never root |
| `TF_VAR_lan_cidrs` | `'["192.168.10.0/24"]'` | what tenants may reach |
| `TF_VAR_client_cidrs` | `'["192.168.10.5/32","192.168.20.7/32"]'` | NUC + workstation |
| `ANSIBLE_BECOME_PASSWORD_FILE` | `~/.config/clanker/become` | optional; lets `just apply` converge without prompting |

If you set a become-password file: `install -m 600 /dev/null ~/.config/clanker/become`, then put the sudo password in it. It must live outside the repo.

## 3. SSH key login

```bash
ssh-copy-id -p "$TF_VAR_ssh_port" "$TF_VAR_admin_user@$TF_VAR_spark_host"
```

The converge refuses to disable password login unless a key is on file, so this step cannot lock you out. It is still required.

## 4. Pin

Skip if the catalog is already pinned (a fork someone pinned, for example).

```bash
just pin                     # images -> sha256 digests, models -> commit SHAs
git diff infra/catalog       # review, then commit
```

## 5. Plan

```bash
just plan
```

Preconditions fail loudly if anything is unpinned, over the GPU budget, colliding on a port, or inconsistent. On the first run `terraform init` writes `infra/terraform/envs/prd/.terraform.lock.hcl`: commit it.

## 6. First converge (accounts, firewall, runtime)

The model services cannot start before their weights exist, so the first pass renders the Ansible inputs without converging, then sets up only the host layer:

```bash
just render                  # terraform apply with converge_on_apply=false
just converge --tags base,runtime,tenants,firewall
```

## 7. Pull

```bash
just pull
```

This opens HTTPS for `svc-inference` and `svc-clanker` only, fetches the pinned vLLM and Qdrant images and every enabled model at its pinned revision, then closes the window. Re-running skips anything already complete.

## 8. Full converge

```bash
just apply                   # or: just converge
```

The run ends with `nvidia-smi -L` inside a rootless container as `svc-inference`. If that step fails, rootless CDI is not working on this driver; see [`SPARK-OPERATIONS.md#troubleshooting`](SPARK-OPERATIONS.md#troubleshooting).

First model start compiles kernels; allow up to 20 minutes before endpoints answer:

```bash
just status                  # all tenants
ssh "$TF_VAR_admin_user@$TF_VAR_spark_host" sudo tenantctl inference logs inference-llm-fast -f
```

## 9. Verify

```bash
just smoke                   # 401 without key, model listed with key, pinned revision reported
just drift                   # must report: No drift.
just outputs                 # endpoints for the LiteLLM model map on the NUC
```

Then work through [`../INFRASTRUCTURE.md §12`](../INFRASTRUCTURE.md#12-hardware-verification-checklist) and relabel **[verify]** items **[measured]**.

## 10. Close the gateway hole

Re-apply the server-VLAN default-deny on the gateway. From here on the Spark reaches the WAN only through `just pull`.
