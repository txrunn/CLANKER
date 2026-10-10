# spark-host: the desired state of one DGX Spark, as a typed contract.
#
# Terraform owns *what* the host should be: tenants, models, images, ports,
# network policy inputs. It validates them, shows the diff in `plan`, renders
# them for Ansible, and triggers a converge when they (or the roles) change.
# Ansible owns *how*: it is the only thing that touches the host.

locals {
  tenants_doc = yamldecode(file("${var.catalog_dir}/tenants.yaml"))
  models_doc  = yamldecode(file("${var.catalog_dir}/models.yaml"))
  images_doc  = yamldecode(file("${var.catalog_dir}/images.yaml"))

  tenants = local.tenants_doc.tenants
  images  = local.images_doc.images

  common_args = try(local.models_doc.defaults.common_args, [])

  # Only enabled models are deployed; disabled ones stay as documented options.
  models = {
    for key, m in local.models_doc.models : key => {
      alias                  = m.alias
      repo                   = m.repo
      revision               = m.revision
      port                   = m.port
      gpu_memory_utilization = m.gpu_memory_utilization
      placement              = m.placement
      consumers              = m.consumers
      provenance             = m.provenance
      read_only              = try(m.read_only, true)
      args                   = concat(local.common_args, m.args)
    } if try(m.enabled, false)
  }

  image_refs = {
    for name, i in local.images : name => "${i.repository}@${coalesce(i.digest, "UNPINNED")}"
  }

  # --- Derived values ---------------------------------------------------------

  model_ports = [for m in values(local.models) : m.port]
  # Ports a tenant publishes for its own services (tenants.yaml `ports`).
  extra_ports   = flatten([for t in values(local.tenants) : try(t.ports, [])])
  service_ports = concat(local.model_ports, values(var.clanker_ports), local.extra_ports)
  # sort() works on strings; zero-pad so ports sort numerically, then convert back.
  tenant_ports = [for p in sort([for x in distinct(local.service_ports) : format("%05d", x)]) : tonumber(p)]

  resident_util = sum(concat([0], [for m in values(local.models) : m.gpu_memory_utilization if m.placement == "resident"]))
  on_demand_max = max(concat([0], [for m in values(local.models) : m.gpu_memory_utilization if m.placement == "on_demand"])...)
  peak_util     = local.resident_util + local.on_demand_max

  # --- What Ansible receives (no secrets: those come from the environment) ----

  host_vars = {
    spark_environment          = var.environment
    spark_admin_user           = var.admin_user
    spark_tenants              = local.tenants
    spark_models               = local.models
    spark_images               = local.image_refs
    spark_tenant_ports         = local.tenant_ports
    spark_clanker_ports        = var.clanker_ports
    spark_pull_window_minutes  = var.pull_window_minutes
    spark_harden_sshd          = var.harden_sshd
    spark_hold_nvidia_packages = var.hold_nvidia_packages
    spark_network = {
      lan_cidrs    = var.lan_cidrs
      client_cidrs = var.client_cidrs
    }
  }

  host_vars_json = jsonencode(local.host_vars)

  ansible_tree_hash = sha256(join(",", [
    for f in sort(fileset(var.ansible_dir, "**")) : "${f}:${filesha256("${var.ansible_dir}/${f}")}"
    if !startswith(f, ".")
  ]))
}

# Catalog invariants. A failed precondition stops `plan` before anything runs.
resource "terraform_data" "catalog" {
  input = {
    models = local.models
    images = local.image_refs
  }

  lifecycle {
    precondition {
      condition     = alltrue([for m in values(local.models) : can(regex("^[0-9a-f]{40}$", coalesce(m.revision, "-")))])
      error_message = "Every enabled model needs a pinned 40-hex revision (NFR-4.3). Run `just pin-models`."
    }

    precondition {
      condition     = alltrue([for i in values(local.images) : can(regex("^sha256:[0-9a-f]{64}$", coalesce(i.digest, "-")))])
      error_message = "Every image needs a sha256 digest (NFR-4.3, SEC-7). Run `just pin-images`."
    }

    precondition {
      condition     = length(local.service_ports) == length(distinct(local.service_ports))
      error_message = "Two enabled services claim the same host port. Ports: ${jsonencode(local.service_ports)}."
    }

    precondition {
      condition     = length(values(local.models)) == length(distinct([for m in values(local.models) : m.alias]))
      error_message = "Two enabled models share an alias. Disable one (e.g. llm-fast vs llm-fast-fallback)."
    }

    precondition {
      condition     = local.peak_util <= local.models_doc.gpu_budget
      error_message = "GPU budget exceeded: resident ${local.resident_util} + largest on-demand ${local.on_demand_max} = ${local.peak_util} > gpu_budget ${local.models_doc.gpu_budget}."
    }

    precondition {
      condition = alltrue([
        for m in values(local.models) : m.provenance.kind == "upstream" || try(m.provenance.evaluation, null) != null
      ])
      error_message = "Derivative models (abliterated, merges, community quants) need provenance.evaluation before they can be enabled. See docs/MODEL-CATALOG.md §5."
    }

    precondition {
      condition     = alltrue(flatten([for m in values(local.models) : [for c in m.consumers : contains(keys(local.tenants), c)]]))
      error_message = "A model lists a consumer that is not a tenant in tenants.yaml."
    }

    precondition {
      condition = alltrue([for name, t in local.tenants : can(regex("^[a-z][a-z0-9-]{1,20}$", name)) && t.uid >= 2000 && t.uid < 60000]) && (
        length(distinct([for t in values(local.tenants) : t.uid])) == length(local.tenants)
      )
      error_message = "Tenant names must be lowercase slugs and uids unique in [2000, 60000)."
    }

    precondition {
      condition     = contains(keys(local.tenants), "inference") && contains(keys(local.tenants), "clanker")
      error_message = "tenants.yaml must define the inference and clanker tenants."
    }
  }
}

resource "local_file" "inventory" {
  filename        = "${var.generated_dir}/inventory.yml"
  file_permission = "0640"
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    environment = var.environment
    spark_host  = var.spark_host
    ssh_port    = var.ssh_port
    admin_user  = var.admin_user
  })

  depends_on = [terraform_data.catalog]
}

resource "local_file" "host_vars" {
  filename        = "${var.generated_dir}/host_vars.json"
  file_permission = "0640"
  content         = local.host_vars_json

  depends_on = [terraform_data.catalog]
}

# Converge when the desired state or the roles change. Drift that happens on
# the host without an input change is caught by `just drift` instead.
resource "terraform_data" "converge" {
  count = var.converge_on_apply ? 1 : 0

  triggers_replace = {
    host_vars = sha256(local.host_vars_json)
    inventory = sha256(local_file.inventory.content)
    roles     = local.ansible_tree_hash
  }

  provisioner "local-exec" {
    working_dir = var.ansible_dir
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [[ -z "$${ANSIBLE_BECOME_PASSWORD_FILE:-}" ]] && ! ssh -p ${var.ssh_port} -o BatchMode=yes ${var.admin_user}@${var.spark_host} sudo -n true 2>/dev/null; then
        echo "Converge needs sudo without a prompt. Set ANSIBLE_BECOME_PASSWORD_FILE in .env, or run 'just converge' to be prompted." >&2
        exit 1
      fi
      ansible-playbook playbooks/site.yml \
        -i '${local_file.inventory.filename}' \
        -e '@${local_file.host_vars.filename}'
    EOT
  }
}
