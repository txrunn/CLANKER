# Hermit pins every operator tool this repo needs (Terraform, just, uv, ...).
# Activate with `. bin/activate-hermit`; tools download on first use.
# Python tooling (ansible-core, ansible-lint, yamllint) is pinned in
# pyproject.toml + uv.lock and installed into .venv by `just bootstrap`.
env = {
  "UV_PROJECT_ENVIRONMENT": "${HERMIT_ENV}/.venv",
  "ANSIBLE_CONFIG": "${HERMIT_ENV}/infra/ansible/ansible.cfg",
  "PATH": "${HERMIT_ENV}/.venv/bin:${PATH}",
}

github-token-auth {
}
