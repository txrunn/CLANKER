output "inventory_path" {
  description = "Rendered Ansible inventory."
  value       = local_file.inventory.filename
}

output "host_vars_path" {
  description = "Rendered Ansible host vars (no secrets)."
  value       = local_file.host_vars.filename
}

output "endpoints" {
  description = "OpenAI-compatible base URL per model alias, as seen from the LAN (for LiteLLM on the NUC)."
  value = {
    for key, m in local.models : m.alias => {
      url       = "http://${var.spark_host}:${m.port}/v1"
      key       = key
      placement = m.placement
      repo      = "${m.repo}@${substr(coalesce(m.revision, "unpinned"), 0, 12)}"
    }
  }
}

output "qdrant_url" {
  description = "Qdrant HTTP endpoint for C.L.A.N.K.E.R. services."
  value       = "http://${var.spark_host}:${var.clanker_ports.qdrant_http}"
}

output "gpu_budget" {
  description = "Planned unified-memory fractions."
  value = {
    resident  = local.resident_util
    on_demand = local.on_demand_max
    peak      = local.peak_util
  }
}

output "nvidia_sync_apps" {
  description = "Entries to add under Custom in NVIDIA Sync (it has no import format)."
  value = concat(
    [for key, m in local.models : {
      name   = "Inference ${m.alias} (${key})"
      port   = m.port
      path   = "docs"
      script = "infra/nvidia-sync/inference-model.sh (set PORT=${m.port})"
    } if m.placement == "resident"],
    [{
      name   = "Qdrant dashboard"
      port   = var.clanker_ports.qdrant_http
      path   = "dashboard"
      script = "infra/nvidia-sync/qdrant.sh"
    }],
  )
}
