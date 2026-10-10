# Instance inputs arrive as TF_VAR_* from the operator's .env (never committed).
# Catalog inputs are read from infra/catalog/*.yaml (committed, instance-free).

variable "environment" {
  description = "Environment name; used for generated-file paths and labels."
  type        = string

  validation {
    condition     = can(regex("^(prd|stg|dev|lab)$", var.environment))
    error_message = "environment must be one of prd, stg, dev, lab."
  }
}

variable "spark_host" {
  description = "Hostname or IP the operator reaches the Spark at (e.g. an mDNS name)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$", var.spark_host)) || can(cidrhost("${var.spark_host}/32", 0))
    error_message = "spark_host must be a hostname or an IPv4 address."
  }
}

variable "ssh_port" {
  description = "SSH port on the Spark."
  type        = number
  default     = 22

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535
    error_message = "ssh_port must be 1-65535."
  }
}

variable "admin_user" {
  description = "Existing sudo-capable account Ansible connects as. Never a tenant, never root."
  type        = string

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user)) && var.admin_user != "root" && !startswith(var.admin_user, "svc-")
    error_message = "admin_user must be a POSIX username, not root, not svc-*."
  }
}

variable "lan_cidrs" {
  description = "Networks tenants may reach (NUC, NAS, DNS). Everything else is WAN and denied."
  type        = list(string)

  validation {
    condition     = length(var.lan_cidrs) > 0 && alltrue([for c in var.lan_cidrs : can(cidrhost(c, 0))])
    error_message = "lan_cidrs must be a non-empty list of CIDRs."
  }
}

variable "client_cidrs" {
  description = "Sources allowed to call tenant ports (NUC, admin workstation). Loopback is always allowed."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.client_cidrs : can(cidrhost(c, 0))])
    error_message = "client_cidrs must be CIDRs (use /32 for a single host)."
  }
}

variable "catalog_dir" {
  description = "Path to infra/catalog."
  type        = string
}

variable "ansible_dir" {
  description = "Path to infra/ansible."
  type        = string
}

variable "generated_dir" {
  description = "Where to write the rendered inventory and host vars (gitignored)."
  type        = string
}

variable "clanker_ports" {
  description = "Host ports for C.L.A.N.K.E.R. services on the Spark."
  type = object({
    qdrant_http = number
    qdrant_grpc = number
  })
  default = {
    qdrant_http = 6333
    qdrant_grpc = 6334
  }
}

variable "pull_window_minutes" {
  description = "Maximum time the HTTPS egress window stays open during `just pull`."
  type        = number
  default     = 120

  validation {
    condition     = var.pull_window_minutes >= 10 && var.pull_window_minutes <= 480
    error_message = "pull_window_minutes must be 10-480."
  }
}

variable "harden_sshd" {
  description = "Key-only SSH, admin user only. Guarded: refuses to apply without an authorized key."
  type        = bool
  default     = true
}

variable "hold_nvidia_packages" {
  description = "apt-mark hold the NVIDIA driver and container toolkit."
  type        = bool
  default     = true
}

variable "converge_on_apply" {
  description = "Run the Ansible converge from `terraform apply` when inputs or roles change."
  type        = bool
  default     = true
}
