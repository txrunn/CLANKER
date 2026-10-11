# C.L.A.N.K.E.R. operator tasks. Run `just` for the list.
#
# Tools are pinned by Hermit (bin/) and uv (pyproject.toml). Instance config
# and secrets are loaded from .env. See docs/runbooks/SPARK-BOOTSTRAP.md.

set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]

# Work without activating Hermit: pinned tools first on PATH.
export PATH := justfile_directory() / "bin" + ":" + justfile_directory() / ".venv/bin" + ":" + env("PATH")
export UV_PROJECT_ENVIRONMENT := justfile_directory() / ".venv"
export ANSIBLE_CONFIG := justfile_directory() / "infra/ansible/ansible.cfg"

tf_dir := "infra/terraform/envs/prd"
gen_dir := "infra/.generated/prd"
ansible_dir := "infra/ansible"
playbook := "ansible-playbook -i ../.generated/prd/inventory.yml -e @../.generated/prd/host_vars.json"
become_flag := if env("ANSIBLE_BECOME_PASSWORD_FILE", "") == "" { "--ask-become-pass" } else { "" }

# List recipes
default:
    @just --list --unsorted

# --- Setup ------------------------------------------------------------------

# Install pinned Python tooling (ansible-core, linters) into .venv
bootstrap:
    uv sync --frozen
    git config core.hooksPath .githooks
    @echo "Tooling ready. Next: just env"

# Create .env from .env.example with freshly generated keys (never overwrites)
env:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -e .env ]]; then echo ".env exists; not touching it."; exit 0; fi
    umask 077
    sed \
      -e "s|^CLANKER_INFERENCE_API_KEY=.*|CLANKER_INFERENCE_API_KEY=$(openssl rand -hex 32)|" \
      -e "s|^CLANKER_QDRANT_API_KEY=.*|CLANKER_QDRANT_API_KEY=$(openssl rand -hex 32)|" \
      .env.example > .env
    echo "Wrote .env (0600). Edit the TF_VAR_* instance values before planning."

# --- Pinning (workstation, needs internet) ----------------------------------

# Resolve image tags to linux/arm64 digests in infra/catalog/images.yaml
pin-images *args:
    infra/scripts/pin-images.sh {{ args }}

# Resolve model repos to commit SHAs in infra/catalog/models.yaml
pin-models *args:
    infra/scripts/pin-models.sh {{ args }}

# Pin everything that is still unpinned
pin: pin-images pin-models

# --- Plan / apply -----------------------------------------------------------

# terraform init (first run writes .terraform.lock.hcl; commit it)
init:
    terraform -chdir={{ tf_dir }} init

# Validate catalog + instance inputs and show what would change
plan: init
    terraform -chdir={{ tf_dir }} plan -out=tfplan

# Render Ansible inputs only (no converge); needed before the first pull
render: init
    terraform -chdir={{ tf_dir }} apply -var converge_on_apply=false

# Render Ansible inputs and converge the host (from the saved plan)
apply:
    terraform -chdir={{ tf_dir }} apply tfplan
    rm -f {{ tf_dir }}/tfplan

# Converge the host directly (interactive sudo prompt if no password file)
converge *args:
    cd {{ ansible_dir }} && {{ playbook }} playbooks/site.yml {{ become_flag }} {{ args }}

# Fail if the host has drifted from the declared state (no changes made)
drift:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ ansible_dir }}
    out=$({{ playbook }} playbooks/site.yml {{ become_flag }} --check --diff | tee /dev/stderr)
    if grep -Eq 'changed=[1-9]' <<<"$out"; then echo "DRIFT DETECTED" >&2; exit 2; fi
    echo "No drift."

# Open the egress window, fetch pinned images and weights, close the window
pull:
    cd {{ ansible_dir }} && {{ playbook }} playbooks/pull.yml {{ become_flag }}

# Self-cleaning hardware check: rootless GPU, pasta UID, Quadlet. No Terraform or pinning needed
spotcheck *args:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f .env ]] || { echo "No .env yet. Run: just env, then set TF_VAR_spark_host and TF_VAR_admin_user in it." >&2; exit 1; }
    [[ -x .venv/bin/ansible-playbook ]] || { echo "Ansible not installed yet. Run: just bootstrap" >&2; exit 1; }
    for v in TF_VAR_spark_host TF_VAR_admin_user; do
      [[ -n "${!v:-}" ]] || { echo "$v is empty in .env." >&2; exit 1; }
    done
    if [[ $TF_VAR_spark_host == spark.local && $TF_VAR_admin_user == admin ]]; then
      echo "Note: .env still has the example host and user (spark.local / admin)." >&2
    fi
    cd {{ ansible_dir }}
    ansible-playbook -i "$TF_VAR_spark_host," -u "$TF_VAR_admin_user" \
      -e ansible_port="${TF_VAR_ssh_port:-22}" playbooks/spotcheck.yml {{ become_flag }} {{ args }}

# Endpoint and auth checks from this workstation
smoke:
    infra/scripts/smoke.sh

# --- Operate ----------------------------------------------------------------

# Start/stop/status an inference model: just model up llm-deep
model action key:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ action }}" in
      up)     verb=start ;;
      down)   verb=stop ;;
      status) verb=status ;;
      *) echo "action must be up, down or status" >&2; exit 64 ;;
    esac
    ssh -t -p "$TF_VAR_ssh_port" "$TF_VAR_admin_user@$TF_VAR_spark_host" \
      sudo tenantctl inference systemctl "$verb" "inference-{{ key }}.service"

# Status of every tenant on the Spark
status:
    ssh -t -p "$TF_VAR_ssh_port" "$TF_VAR_admin_user@$TF_VAR_spark_host" \
      'for t in inference clanker stratum; do echo "== $t"; sudo tenantctl $t status; done'

# Print outputs (endpoints, GPU budget, NVIDIA Sync entries)
outputs:
    terraform -chdir={{ tf_dir }} output

# Remove what converge created; keeps /srv/<tenant> unless -e purge=true (asks for the host name)
teardown *args:
    cd {{ ansible_dir }} && {{ playbook }} playbooks/teardown.yml {{ become_flag }} {{ args }}

# --- Quality gates ----------------------------------------------------------

# Every static check; runs offline
lint: lint-terraform lint-ansible lint-shell lint-secrets

# terraform fmt, validate, tflint
lint-terraform:
    terraform fmt -check -recursive infra/terraform
    terraform -chdir={{ tf_dir }} validate
    cd infra/terraform && tflint --init && tflint --recursive

# ansible-lint (production profile) and yamllint
lint-ansible:
    cd {{ ansible_dir }} && ansible-lint --profile production playbooks/ roles/
    yamllint -s infra/catalog infra/ansible

# shellcheck every script
lint-shell:
    shellcheck infra/scripts/*.sh infra/nvidia-sync/*.sh infra/ansible/roles/host_base/files/tenantctl .githooks/pre-commit

# gitleaks over the working tree
lint-secrets:
    gitleaks detect --no-banner --redact --source .
