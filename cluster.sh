#!/usr/bin/env bash
#
# cluster.sh - reproducible three-node kubeadm cluster on Lima + socket_vmnet.
#
#   ./cluster.sh up          build the cluster from nothing
#   ./cluster.sh down        delete all three VMs
#   ./cluster.sh stop        stop the VMs, keep the disks
#   ./cluster.sh start       start previously stopped VMs
#   ./cluster.sh status      node and pod summary
#   ./cluster.sh kubeconfig  print the export line for your shell
#   ./cluster.sh metallb     install MetalLB in L2 mode
#   ./cluster.sh preflight   check the host is ready, change nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/k8s-node.yaml"

CP_NAME="${CP_NAME:-cp1}"
WORKER_NAMES="${WORKER_NAMES:-w1 w2}"
CP_CPUS="${CP_CPUS:-2}"
CP_MEMORY="${CP_MEMORY:-4}"
WORKER_CPUS="${WORKER_CPUS:-2}"
WORKER_MEMORY="${WORKER_MEMORY:-4}"

## MetalLB pool. Must sit above dhcpEnd in ~/.lima/_config/networks.yaml,
## otherwise socket_vmnet will hand these addresses to VMs and you get an
## ARP fight between MetalLB and a node.
#
METALLB_RANGE="${METALLB_RANGE:-192.168.105.200-192.168.105.250}"
DHCP_END="${DHCP_END:-192.168.105.199}"

NETWORKS_YAML="${HOME}/.lima/_config/networks.yaml"
SUDOERS_FILE="/etc/sudoers.d/lima"

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m!!\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mxx\033[0m %s\n' "$*" >&2
  exit 1
}

instance_exists() {
  limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "${1}"
}

cp_dir() {
  limactl list "${CP_NAME}" --format '{{.Dir}}'
}

preflight() {
  local missing=0

  for binary in limactl kubectl
  do
    if ! command -v "${binary}" >/dev/null 2>&1
    then
      warn "missing ${binary}"
      missing=1
    fi
  done

  if [ ! -x /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /usr/local/opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /opt/socket_vmnet/bin/socket_vmnet ]
  then
    warn "socket_vmnet not found; run: brew install socket_vmnet"
    missing=1
  fi

  ## Lima refuses a `lima: shared` network without this file, and the error it
  ## prints points at the wrong thing.
  #
  if [ ! -f "${SUDOERS_FILE}" ]
  then
    warn "missing ${SUDOERS_FILE}; run: limactl sudoers | sudo tee ${SUDOERS_FILE}"
    missing=1
  fi

  if [ -f "${NETWORKS_YAML}" ] && grep -q 'dhcpEnd: *192\.168\.105\.254' "${NETWORKS_YAML}"
  then
    warn "dhcpEnd is still .254 in ${NETWORKS_YAML}"
    warn "set it to ${DHCP_END} before using ./cluster.sh metallb"
  fi

  [ ! -f "${TEMPLATE}" ] && die "template not found: ${TEMPLATE}"

  if [ "${missing}" -ne 0 ]
  then
    die "preflight failed"
  fi
  log "preflight ok"
}

start_control_plane() {
  if instance_exists "${CP_NAME}"
  then
    log "${CP_NAME} already exists, starting it"
    limactl start "${CP_NAME}"
    return
  fi

  log "creating control plane ${CP_NAME}"
  limactl start \
    --name="${CP_NAME}" \
    --cpus="${CP_CPUS}" \
    --memory="${CP_MEMORY}" \
    --tty=false \
    "${TEMPLATE}"
}

join_workers() {
  local join_cmd url token hash

  log "reading join credentials from ${CP_NAME}"
  join_cmd="$(limactl shell "${CP_NAME}" sudo kubeadm token create --print-join-command)"
  url="$(echo "${join_cmd}" | awk '{print $3}')"
  token="$(echo "${join_cmd}" | awk '{for (i=1;i<=NF;i++) if ($i=="--token") print $(i+1)}')"
  hash="$(echo "${join_cmd}" | awk '{for (i=1;i<=NF;i++) if ($i=="--discovery-token-ca-cert-hash") print $(i+1)}')"

  [ -z "${url}" ] && die "could not parse API endpoint from join command"
  log "api endpoint ${url}"

  for worker in ${WORKER_NAMES}
  do
    if instance_exists "${worker}"
    then
      log "${worker} already exists, starting it"
      limactl start "${worker}"
      continue
    fi
    log "creating worker ${worker}"
    limactl start \
      --name="${worker}" \
      --cpus="${WORKER_CPUS}" \
      --memory="${WORKER_MEMORY}" \
      --tty=false \
      --param url="${url}" \
      --param token="${token}" \
      --param discoveryTokenCaCertHash="${hash}" \
      "${TEMPLATE}"
  done
}

label_workers() {
  local kubeconfig
  kubeconfig="$(cp_dir)/copied-from-guest/kubeconfig.yaml"

  for worker in ${WORKER_NAMES}
  do
    kubectl --kubeconfig="${kubeconfig}" label node "lima-${worker}" \
      node-role.kubernetes.io/worker=worker --overwrite >/dev/null 2>&1 || true
  done
}

install_metallb() {
  local kubeconfig version
  kubeconfig="$(cp_dir)/copied-from-guest/kubeconfig.yaml"

  version="${METALLB_VERSION:-$(curl -fsSL https://api.github.com/repos/metallb/metallb/releases/latest \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)}"
  [ -z "${version}" ] && die "could not determine MetalLB version; set METALLB_VERSION"

  log "installing MetalLB ${version}"
  kubectl --kubeconfig="${kubeconfig}" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${version}/config/manifests/metallb-native.yaml"

  log "waiting for the MetalLB webhook"
  kubectl --kubeconfig="${kubeconfig}" wait -n metallb-system \
    --for=condition=available --timeout=300s deploy/controller

  log "configuring L2 pool ${METALLB_RANGE}"
  kubectl --kubeconfig="${kubeconfig}" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lima-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lima-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - lima-pool
EOF
  log "LoadBalancer services will now get VIPs your Mac can reach directly"
}

show_status() {
  local kubeconfig
  kubeconfig="$(cp_dir)/copied-from-guest/kubeconfig.yaml"

  limactl list
  echo
  kubectl --kubeconfig="${kubeconfig}" get nodes -o wide
  echo
  kubectl --kubeconfig="${kubeconfig}" get pods -A
}

show_kubeconfig() {
  echo "export KUBECONFIG=\"$(cp_dir)/copied-from-guest/kubeconfig.yaml\""
}

do_up() {
  preflight
  start_control_plane
  join_workers
  label_workers
  echo
  log "cluster up"
  show_kubeconfig
}

do_down() {
  for instance in ${WORKER_NAMES} ${CP_NAME}
  do
    if instance_exists "${instance}"
    then
      log "deleting ${instance}"
      limactl delete --force "${instance}"
    fi
  done
}

do_stop() {
  for instance in ${WORKER_NAMES} ${CP_NAME}
  do
    if instance_exists "${instance}"
    then
      limactl stop "${instance}" || true
    fi
  done
}

do_start() {
  limactl start "${CP_NAME}"
  for worker in ${WORKER_NAMES}
  do
    limactl start "${worker}"
  done
}

case "${1:-up}" in
  up)
    do_up
    ;;
  down)
    do_down
    ;;
  stop)
    do_stop
    ;;
  start)
    do_start
    ;;
  status)
    show_status
    ;;
  kubeconfig)
    show_kubeconfig
    ;;
  metallb)
    install_metallb
    ;;
  preflight)
    preflight
    ;;
  *)
    die "unknown command: ${1}"
    ;;
esac
