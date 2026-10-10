output "endpoints" {
  description = "Model endpoints by alias, for the LiteLLM model map on the NUC."
  value       = module.spark.endpoints
}

output "qdrant_url" {
  description = "Qdrant endpoint for the memory service and RAG."
  value       = module.spark.qdrant_url
}

output "gpu_budget" {
  description = "Planned unified-memory fractions (resident, largest on-demand, peak)."
  value       = module.spark.gpu_budget
}

output "nvidia_sync_apps" {
  description = "Custom app entries for NVIDIA Sync. See docs/runbooks/NVIDIA-SYNC.md."
  value       = module.spark.nvidia_sync_apps
}

output "generated" {
  description = "Rendered Ansible inputs."
  value = {
    inventory = module.spark.inventory_path
    host_vars = module.spark.host_vars_path
  }
}
