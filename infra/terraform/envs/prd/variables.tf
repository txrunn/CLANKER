# Everything instance-specific is supplied by .env as TF_VAR_* (see .env.example).
# Validation lives in the module; these only declare and document.

variable "spark_host" {
  description = "Hostname or IP of the Spark (TF_VAR_spark_host)."
  type        = string
}

variable "ssh_port" {
  description = "SSH port on the Spark (TF_VAR_ssh_port)."
  type        = number
  default     = 22
}

variable "admin_user" {
  description = "Existing sudo-capable admin account on the Spark (TF_VAR_admin_user)."
  type        = string
}

variable "lan_cidrs" {
  description = "LAN networks tenants may reach (TF_VAR_lan_cidrs, HCL list)."
  type        = list(string)
}

variable "client_cidrs" {
  description = "Sources allowed to call tenant ports (TF_VAR_client_cidrs, HCL list)."
  type        = list(string)
}

variable "converge_on_apply" {
  description = "Run Ansible from terraform apply (TF_VAR_converge_on_apply)."
  type        = bool
  default     = true
}
