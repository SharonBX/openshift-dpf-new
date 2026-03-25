#!/bin/bash
# Runs before kubelet (99-worker-bridge → worker-nmstate-bridge). DPU host kubelet-env is written here (BF3 only), not as Ignition storage.files.
#
# 1) Sanitize /etc/kubernetes/kubelet-env: kubelet only applies labels under *.node.kubernetes.io and
#    kubelet.kubernetes.io (k8s.io/kubelet/pkg/apis IsKubeletLabel). Strip mistaken node-role…/worker-dpu
#    and legacy k8s.ovn.org/dpu-host= (OVN namespace — kubelet never applies it; matches worker-dpu MCP).
# 2) If BF3-class PCI is present (Mellanox 15b3 / a2d6|a2dc):
#    - Create /run/dpu-worker-network for systemd ConditionPathExists= (nmstate-bridge, p0-routing).
#    - Ensure CUSTOM_KUBELET_LABELS includes feature.node.kubernetes.io/dpu-enabled=true (worker-dpu MCP;
#      same value NFD typically uses; CNO hardware-offload-config may use empty or true per site).
#
# Non-DPU workers: do not touch kubelet-env for pool labels (only sanitize disallowed keys if file exists).
#
# If /run/dpu-worker-network exists but kubelet-env lacks feature.node.kubernetes.io/dpu-enabled=true (old MC,
# failed write, or manual re-run where PCI is invisible e.g. debug shell), we still run ensure — stamp
# implies DPU this boot.
#
# If another MachineConfig also defines /etc/kubernetes/kubelet-env, MCD may overwrite this file — avoid
# duplicate ownership or use oc label / a dedicated MC for mixed clusters.
set -euo pipefail

DPU_VENDOR="15b3"
DPU_DEVICES="a2d6 a2dc"
KUBELET_ENV="/etc/kubernetes/kubelet-env"
FORBIDDEN_ROLE_KEY="node-role.kubernetes.io/worker-dpu"
# k8s.ovn.org/* is not kubelet-writable; OVN/CNO use feature.node… for DPU host mode with NFD.
LEGACY_NON_KUBELET_DPU_KEY="k8s.ovn.org/dpu-host"
DPU_WORKER_POOL_LABEL_KEY="feature.node.kubernetes.io/dpu-enabled"
DPU_WORKER_POOL_LABEL_ENTRY="feature.node.kubernetes.io/dpu-enabled=true"

label_key() {
  local s="$1"
  case "$s" in
    *=*) printf '%s' "${s%%=*}" ;;
    *) printf '%s' "$s" ;;
  esac
}

# Remove kubelet-inapplicable keys from CUSTOM_KUBELET_LABELS (if present).
sanitize_forbidden_role_from_kubelet_env() {
  local val new_val="" p k
  [[ -f "$KUBELET_ENV" ]] || return 0
  grep -q '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" 2>/dev/null || return 0
  if ! grep -qF "${FORBIDDEN_ROLE_KEY}=" "$KUBELET_ENV" && ! grep -qF "${LEGACY_NON_KUBELET_DPU_KEY}=" "$KUBELET_ENV"; then
    return 0
  fi
  val=$(grep '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" | tail -1)
  val="${val#CUSTOM_KUBELET_LABELS=}"
  new_val=""
  IFS=',' read -ra parts <<< "$val" || true
  for p in "${parts[@]}"; do
    p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$p" ]] && continue
    k=$(label_key "$p")
    [[ "$k" == "$FORBIDDEN_ROLE_KEY" || "$k" == "$LEGACY_NON_KUBELET_DPU_KEY" ]] && continue
    if [[ -n "$new_val" ]]; then
      new_val="${new_val},${p}"
    else
      new_val="${p}"
    fi
  done
  local tmp
  tmp=$(mktemp)
  grep -v '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" >"$tmp" || true
  if [[ -n "$new_val" ]]; then
    echo "CUSTOM_KUBELET_LABELS=${new_val}" >>"$tmp"
  fi
  mv "$tmp" "$KUBELET_ENV"
  chmod 0644 "$KUBELET_ENV" 2>/dev/null || true
}

# Only when BF3/DPU PCI matched: ensure worker-dpu MCP label is in kubelet-env.
ensure_dpu_host_in_kubelet_env() {
  local val new_val="" p k found=0 tmp
  if [[ ! -f "$KUBELET_ENV" ]]; then
    echo "CUSTOM_KUBELET_LABELS=${DPU_WORKER_POOL_LABEL_ENTRY}" >"$KUBELET_ENV"
    chmod 0644 "$KUBELET_ENV"
    return 0
  fi
  if ! grep -q '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" 2>/dev/null; then
    echo "CUSTOM_KUBELET_LABELS=${DPU_WORKER_POOL_LABEL_ENTRY}" >>"$KUBELET_ENV"
    chmod 0644 "$KUBELET_ENV"
    return 0
  fi
  val=$(grep '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" | tail -1)
  val="${val#CUSTOM_KUBELET_LABELS=}"
  IFS=',' read -ra parts <<< "$val" || true
  for p in "${parts[@]}"; do
    p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$p" ]] && continue
    k=$(label_key "$p")
    if [[ "$k" == "$DPU_WORKER_POOL_LABEL_KEY" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 1 ]]; then
    return 0
  fi
  new_val="${val},${DPU_WORKER_POOL_LABEL_ENTRY}"
  new_val="${new_val#,}"
  tmp=$(mktemp)
  grep -v '^CUSTOM_KUBELET_LABELS=' "$KUBELET_ENV" >"$tmp" || true
  echo "CUSTOM_KUBELET_LABELS=${new_val}" >>"$tmp"
  mv "$tmp" "$KUBELET_ENV"
  chmod 0644 "$KUBELET_ENV"
}

sanitize_forbidden_role_from_kubelet_env


dpu_found=0
if command -v lspci >/dev/null 2>&1; then
  for dev in $DPU_DEVICES; do
    if lspci -nn -d "${DPU_VENDOR}:${dev}" 2>/dev/null | grep -q .; then
      dpu_found=1
      break
    fi
  done
fi

if [ "$dpu_found" -eq 0 ]; then
  for d in /sys/bus/pci/devices/*; do
    [ -f "${d}/vendor" ] && [ -f "${d}/device" ] || continue
    v=$(tr -d '[:space:]' < "${d}/vendor" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    dv=$(tr -d '[:space:]' < "${d}/device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    for dev in $DPU_DEVICES; do
      if [ "$v" = "0x${DPU_VENDOR}" ] && [ "$dv" = "0x${dev}" ]; then
        dpu_found=1
        break 2
      fi
    done
  done
fi

if [ "$dpu_found" -eq 1 ]; then
  # Write kubelet-env before stamp so we never leave stamp without env if ensure fails.
  ensure_dpu_host_in_kubelet_env
  : >/run/dpu-worker-network
elif [[ -f /run/dpu-worker-network ]]; then
  # Heal: stamp from this boot but env missing (older embedded script, or PCI not visible in this context).
  ensure_dpu_host_in_kubelet_env
fi

exit 0

