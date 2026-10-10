# Production compute host for C.L.A.N.K.E.R.
#
#   just plan    # validate catalog + inputs, show the diff
#   just apply   # render inventory/vars and converge the host

locals {
  repo_root = abspath("${path.root}/../../../..")
}

module "spark" {
  source = "../../modules/spark-host"

  environment  = "prd"
  spark_host   = var.spark_host
  ssh_port     = var.ssh_port
  admin_user   = var.admin_user
  lan_cidrs    = var.lan_cidrs
  client_cidrs = var.client_cidrs

  catalog_dir   = "${local.repo_root}/infra/catalog"
  ansible_dir   = "${local.repo_root}/infra/ansible"
  generated_dir = "${local.repo_root}/infra/.generated/prd"

  converge_on_apply = var.converge_on_apply
}
