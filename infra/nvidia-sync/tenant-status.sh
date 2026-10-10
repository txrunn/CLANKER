#!/usr/bin/env bash
# NVIDIA Sync custom app: one-screen status of every tenant and the GPU.
#
# Paste into Sync > Custom > Add New, with:
#   Name: Spark tenants    Port: any free port (e.g. 18999; Sync requires one)
#   Launch in Terminal: checked
set -euo pipefail

nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,power.draw --format=csv
echo
for t in $(getent passwd | awk -F: '$1 ~ /^svc-/ {sub("svc-", "", $1); print $1}'); do
  echo "== $t"
  sudo tenantctl "$t" status | sed -n '1,/^$/p'
done
echo
echo "Egress drops in the last hour:"
sudo journalctl -k --since -1h --no-pager | grep -c 'spark-egress-drop' || true
