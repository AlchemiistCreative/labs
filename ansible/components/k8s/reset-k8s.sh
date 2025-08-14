#!/usr/bin/env bash
set -euo pipefail

# Default values
VERBOSE=false
DRY_RUN=false
PARALLEL=false
HOSTS=()

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -T -q'

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --hosts "host1 host2 ..."      List of hosts to reset
  --hosts-file <file>           File with one host per line
  --verbose, -v                 Enable verbose output
  --dry-run                     Show which hosts would be reset
  --serial                      Run resets serially (default)
  --parallel                    Run resets in parallel
  --help                        Show this help message
EOF
  exit 1
}

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)
      read -r -a HOSTS <<< "$2"
      shift 2
      ;;
    --hosts-file)
      mapfile -t HOSTS < "$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --serial)
      PARALLEL=false
      shift
      ;;
    --parallel)
      PARALLEL=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

[[ ${#HOSTS[@]} -eq 0 ]] && echo "Error: No hosts provided." && usage

log_info()   { echo "[INFO] $*"; }
log_ok()     { echo "[OK] $*"; }

remote_reset() {
  set -euo pipefail
  H=$(hostname -f 2>/dev/null || hostname)
  echo "$H: [0] stop kubelet + remove static manifests"
  sudo rm -rf /tmp/kubeadm.lock
  sudo systemctl stop kubelet 2>/dev/null || true
  sudo rm -f /etc/kubernetes/manifests/{kube-apiserver.yaml,kube-controller-manager.yaml,kube-scheduler.yaml,etcd.yaml} 2>/dev/null || true

  echo "$H: [1] ensure containerd is running"
  sudo systemctl start containerd 2>/dev/null || true
  sleep 1

  CRI_ENDPOINT="unix:///run/containerd/containerd.sock"

  if command -v crictl >/dev/null 2>&1; then
    sudo crictl --runtime-endpoint "$CRI_ENDPOINT" ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler|etcd/ {print $1}' | xargs -r sudo crictl --runtime-endpoint "$CRI_ENDPOINT" stop || true
    sudo crictl --runtime-endpoint "$CRI_ENDPOINT" ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler|etcd/ {print $1}' | xargs -r sudo crictl --runtime-endpoint "$CRI_ENDPOINT" rm   || true
  fi
  if command -v ctr >/dev/null 2>&1; then
    sudo ctr -n k8s.io c ls | awk '/kube-apiserver|kube-controller-manager|kube-scheduler|etcd/ {print $1}' | xargs -r -I{} sudo ctr -n k8s.io c rm -f {} || true
  fi
  if command -v nerdctl >/dev/null 2>&1; then
    sudo nerdctl -n k8s.io ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler|etcd/ {print $1}' | xargs -r sudo nerdctl -n k8s.io rm -f || true
  fi
  if command -v docker >/dev/null 2>&1; then
    sudo docker ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler|etcd/ {print $1}' | xargs -r sudo docker rm -f || true
  fi

  echo "$H: [2] kill :6443 + stop containerd"
  sudo fuser -k 6443/tcp 2>/dev/null || true
  sudo systemctl stop containerd 2>/dev/null || true

  for i in {1..20}; do
    ss -lntp | grep -q ':6443 ' && sleep 1 || { echo "$H: 6443 free"; break; }
    [ "$i" -eq 20 ] && { echo "$H: 6443 still busy"; exit 1; }
  done

  echo "$H: [3] kubeadm reset + purge dirs"
  sudo kubeadm reset -f 2>/dev/null || true
  sudo crictl --runtime-endpoint "$CRI_ENDPOINT" rm -af 2>/dev/null || true
  sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /var/lib/cni /etc/cni/net.d /opt/cni /root/.kube

  echo "$H: [4] runtime/config cleanup"
  sudo rm -rf /var/lib/containerd /etc/containerd /var/lib/docker /etc/docker

  echo "$H: [5] network cleanup"
  sudo ip link del cni0 2>/dev/null || true
  sudo ip link del flannel.1 2>/dev/null || true
  sudo iptables -F 2>/dev/null || true
  sudo iptables -t nat -F 2>/dev/null || true
  sudo iptables -t mangle -F 2>/dev/null || true
  sudo nft flush ruleset 2>/dev/null || true

  echo "$H: [6] stop/mask firewalld"
  sudo systemctl stop firewalld 2>/dev/null || true
  sudo systemctl disable firewalld 2>/dev/null || true
  sudo systemctl mask firewalld 2>/dev/null || true

  echo "$H: [7] restart containerd"
  sudo systemctl start containerd 2>/dev/null || true

  echo "$H: ✅ hard reset complete"
}

reset_node() {
  local host="$1"
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[dry-run] would reset $host"
    return
  fi

  if [[ "$VERBOSE" == true ]]; then
    ssh $SSH_OPTS "$USER@$host" "$(typeset -f remote_reset); remote_reset"
  else
    ssh $SSH_OPTS "$USER@$host" "$(typeset -f remote_reset); remote_reset" > /dev/null 2>&1
  fi
  log_ok "$host reset complete"
}

# Execute
if [[ "$PARALLEL" == true ]]; then
  for h in "${HOSTS[@]}"; do
    reset_node "$h" &
  done
  wait
else
  for h in "${HOSTS[@]}"; do
    reset_node "$h"
  done
fi

