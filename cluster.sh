#!/usr/bin/env bash
#
# cluster.sh - reproducible three-node kubeadm cluster on Lima + socket_vmnet.
#
#   ./cluster.sh up          build the cluster from nothing
#   ./cluster.sh down        delete all three VMs
#   ./cluster.sh stop        stop the VMs, keep the disks
#   ./cluster.sh start       start previously stopped VMs
#   ./cluster.sh status      node and pod summary
#   ./cluster.sh check       run the cluster health checks, echoing each command
#   ./cluster.sh kubeconfig  print the export line for your shell
#   ./cluster.sh metallb     install MetalLB in L2 mode
#   ./cluster.sh preflight   check the host is ready, change nothing

set -euo pipefail

## socket_vmnet runs under sudo but inherits the caller's umask. With a
## restrictive umask (077) its pid file and socket land 0600 root:wheel and
## limactl, running as you, cannot read them back.
#
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
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

##################################################################################################################################################
## log
## pipeline-relevant log output
## Usage: log "ERROR" "${FUNCNAME[0]}" "Wrong number of arguments to log_run"
#
function log {
  red="\033[1;31m"
  green="\033[1;32m"
  yellow="\033[1;33m"
  blue="\033[1;34m"
  purple="\033[1;35m"
  cyan="\033[1;36m"
  white="\033[1;37m"
  reset="\033[0m"

  local -r level="${1}"
  if [ "${level}" == "INFO" ]
  then
    COL=${green}
  elif [ "${level}" == "ERROR" ]
  then
    COL=${red}
  elif [ "${level}" == "WARN" ]
  then
    COL=${yellow}
  elif [ "${level}" == "CMD" ]
  then
    COL=${purple}
  elif [ "${level}" == "OK" ]
  then
    COL=${green}
  elif [ "${level}" == "FAIL" ]
  then
    COL=${red}
  else
    COL=${white}
  fi

  local -r func="${2}"
  local -r message="${3}"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S %Z")
  >&2 echo -e "${cyan}${timestamp}${reset} [${COL}${level}${reset}] [${cyan}${SCRIPT_NAME}${reset}:${yellow}${func}${reset}] ${message}"
}

##################################################################################################################################################
## die
## log at ERROR and exit non-zero
#
function die {
  log "ERROR" "${2:-${FUNCNAME[1]}}" "${1}"
  exit 1
}

##################################################################################################################################################
## assert_binary
## fail early and loudly if a required binary is not on PATH
## Usage: assert_binary "kubectl" "install with: brew install kubectl"
#
function assert_binary {
  local -r binary="${1}"
  local -r remedy="${2:-}"

  if ! command -v "${binary}" >/dev/null 2>&1
  then
    log "ERROR" "${FUNCNAME[0]}" "required binary not on PATH: ${binary}"
    if [ -n "${remedy}" ]
    then
      log "ERROR" "${FUNCNAME[0]}" "${remedy}"
    fi
    return 1
  fi

  log "INFO" "${FUNCNAME[0]}" "found ${binary} at $(command -v "${binary}")"
  return 0
}

##################################################################################################################################################
## assert_kubeconfig
## fail early if the control plane kubeconfig has not been copied to the host yet
#
function assert_kubeconfig {
  local -r kubeconfig="${1}"

  if [ ! -s "${kubeconfig}" ]
  then
    log "ERROR" "${FUNCNAME[0]}" "kubeconfig missing or empty: ${kubeconfig}"
    log "ERROR" "${FUNCNAME[0]}" "is ${CP_NAME} running? try: ./${SCRIPT_NAME} up"
    return 1
  fi

  log "INFO" "${FUNCNAME[0]}" "using kubeconfig ${kubeconfig}"
  return 0
}

##################################################################################################################################################
## run_check
## echo the command at CMD level so it can be re-run by hand, then run it and
## print the output verbatim
## Usage: run_check "nodes and their lima0 addresses" kubectl get nodes -o wide
#
function run_check {
  local -r description="${1}"
  shift

  log "INFO" "${FUNCNAME[1]}" "${description}"
  log "CMD" "${FUNCNAME[1]}" "$*"

  local output rc=0
  output="$("$@" 2>&1)" || rc=$?

  if [ -n "${output}" ]
  then
    echo "${output}"
  fi

  if [ "${rc}" -ne 0 ]
  then
    log "FAIL" "${FUNCNAME[1]}" "exit ${rc}"
    return "${rc}"
  fi

  log "OK" "${FUNCNAME[1]}" "exit 0"
  return 0
}

instance_exists() {
  ## A failed create leaves the instance directory behind while `limactl list`
  ## may not report it, so check both.
  #
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "${1}"
  then
    return 0
  fi
  [ -d "${LIMA_HOME:-${HOME}/.lima}/${1}" ]
}

cp_dir() {
  limactl list "${CP_NAME}" --format '{{.Dir}}'
}

kubeconfig_path() {
  echo "$(cp_dir)/copied-from-guest/kubeconfig.yaml"
}

preflight() {
  local missing=0

  assert_binary "limactl" "install with: brew install lima" || missing=1
  assert_binary "kubectl" "install with: brew install kubectl" || missing=1

  if [ ! -x /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /usr/local/opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /opt/socket_vmnet/bin/socket_vmnet ]
  then
    log "ERROR" "${FUNCNAME[0]}" "socket_vmnet not found in any known prefix"
    log "ERROR" "${FUNCNAME[0]}" "build it: sudo make PREFIX=/opt/socket_vmnet install.bin"
    missing=1
  else
    log "INFO" "${FUNCNAME[0]}" "socket_vmnet present"
  fi

  ## Lima refuses a `lima: shared` network without this file, and the error it
  ## prints points at the wrong thing.
  #
  if [ ! -f "${SUDOERS_FILE}" ]
  then
    log "ERROR" "${FUNCNAME[0]}" "missing ${SUDOERS_FILE}"
    log "ERROR" "${FUNCNAME[0]}" "run: limactl sudoers > /tmp/l && sudo install -o root -g wheel -m 0644 /tmp/l ${SUDOERS_FILE}"
    missing=1
  else
    log "INFO" "${FUNCNAME[0]}" "sudoers file present"
  fi

  if [ -f "${NETWORKS_YAML}" ] && grep -q 'dhcpEnd: *192\.168\.105\.254' "${NETWORKS_YAML}"
  then
    log "WARN" "${FUNCNAME[0]}" "dhcpEnd is still .254 in ${NETWORKS_YAML}"
    log "WARN" "${FUNCNAME[0]}" "set it to ${DHCP_END} before using ./${SCRIPT_NAME} metallb"
  fi

  ## Leftover 0600 root-owned pid/socket files from a run under a restrictive
  ## umask will fail every subsequent start until they are cleared.
  #
  if [ -d /private/var/run/lima ]
  then
    if find /private/var/run/lima -maxdepth 1 -type f ! -perm -044 2>/dev/null | grep -q .
    then
      log "WARN" "${FUNCNAME[0]}" "unreadable files in /private/var/run/lima from an earlier run"
      log "WARN" "${FUNCNAME[0]}" "run: sudo pkill -f socket_vmnet; sudo rm -rf /private/var/run/lima"
    fi
  fi

  if [ ! -f "${TEMPLATE}" ]
  then
    die "template not found: ${TEMPLATE}" "${FUNCNAME[0]}"
  fi

  if [ "${missing}" -ne 0 ]
  then
    die "preflight failed" "${FUNCNAME[0]}"
  fi
  log "INFO" "${FUNCNAME[0]}" "preflight ok"
}

start_control_plane() {
  if instance_exists "${CP_NAME}"
  then
    log "INFO" "${FUNCNAME[0]}" "${CP_NAME} already exists, starting it"
    limactl start "${CP_NAME}"
    return
  fi

  log "INFO" "${FUNCNAME[0]}" "creating control plane ${CP_NAME} (${CP_CPUS} vCPU, ${CP_MEMORY}GiB)"
  limactl start \
    --name="${CP_NAME}" \
    --cpus="${CP_CPUS}" \
    --memory="${CP_MEMORY}" \
    --tty=false \
    "${TEMPLATE}"
}

join_workers() {
  local join_cmd url token hash

  log "INFO" "${FUNCNAME[0]}" "reading join credentials from ${CP_NAME}"
  join_cmd="$(limactl shell "${CP_NAME}" sudo kubeadm token create --print-join-command)"
  url="$(echo "${join_cmd}" | awk '{print $3}')"
  token="$(echo "${join_cmd}" | awk '{for (i=1;i<=NF;i++) if ($i=="--token") print $(i+1)}')"
  hash="$(echo "${join_cmd}" | awk '{for (i=1;i<=NF;i++) if ($i=="--discovery-token-ca-cert-hash") print $(i+1)}')"

  if [ -z "${url}" ]
  then
    die "could not parse API endpoint from join command" "${FUNCNAME[0]}"
  fi
  log "INFO" "${FUNCNAME[0]}" "api endpoint ${url}"

  for worker in ${WORKER_NAMES}
  do
    if instance_exists "${worker}"
    then
      log "INFO" "${FUNCNAME[0]}" "${worker} already exists, starting it"
      limactl start "${worker}"
      continue
    fi

    ## A worker that joined and was then deleted leaves its Node object behind.
    ## kubeadm join refuses to reuse the name, so clear it first.
    #
    log "INFO" "${FUNCNAME[0]}" "clearing any stale node object lima-${worker}"
    limactl shell "${CP_NAME}" sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf \
      delete node "lima-${worker}" --ignore-not-found >/dev/null 2>&1 || true

    log "INFO" "${FUNCNAME[0]}" "creating worker ${worker} (${WORKER_CPUS} vCPU, ${WORKER_MEMORY}GiB)"
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
  kubeconfig="$(kubeconfig_path)"

  for worker in ${WORKER_NAMES}
  do
    log "INFO" "${FUNCNAME[0]}" "labelling lima-${worker} as worker"
    kubectl --kubeconfig="${kubeconfig}" label node "lima-${worker}" \
      node-role.kubernetes.io/worker=worker --overwrite >/dev/null 2>&1 || true
  done
}

install_metallb() {
  local kubeconfig version
  kubeconfig="$(kubeconfig_path)"

  assert_binary "kubectl" "install with: brew install kubectl" || exit 1
  assert_kubeconfig "${kubeconfig}" || exit 1

  version="${METALLB_VERSION:-$(curl -fsSL https://api.github.com/repos/metallb/metallb/releases/latest \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)}"
  if [ -z "${version}" ]
  then
    die "could not determine MetalLB version; set METALLB_VERSION" "${FUNCNAME[0]}"
  fi

  log "INFO" "${FUNCNAME[0]}" "installing MetalLB ${version}"
  kubectl --kubeconfig="${kubeconfig}" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${version}/config/manifests/metallb-native.yaml"

  log "INFO" "${FUNCNAME[0]}" "waiting for the MetalLB webhook"
  kubectl --kubeconfig="${kubeconfig}" wait -n metallb-system \
    --for=condition=available --timeout=300s deploy/controller

  log "INFO" "${FUNCNAME[0]}" "configuring L2 pool ${METALLB_RANGE}"
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
  log "INFO" "${FUNCNAME[0]}" "LoadBalancer services will now get VIPs your Mac can reach directly"
}

##################################################################################################################################################
## run_checks
## the post-build verification suite. Every command is echoed at CMD level so it
## can be pasted straight into a shell when a check needs digging into.
#
function run_checks {
  local kubeconfig failures=0
  kubeconfig="$(kubeconfig_path)"

  assert_binary "kubectl" "install with: brew install kubectl" || exit 1
  assert_binary "limactl" "install with: brew install lima" || exit 1
  assert_kubeconfig "${kubeconfig}" || exit 1

  local -r kc=(kubectl --kubeconfig="${kubeconfig}")

  log "INFO" "${FUNCNAME[0]}" "export KUBECONFIG=\"${kubeconfig}\" to run these by hand"

  run_check "lima instance states" \
    limactl list || failures=$((failures + 1))

  run_check "api server endpoint, reached over socket_vmnet not a forwarded port" \
    "${kc[@]}" cluster-info || failures=$((failures + 1))

  ## INTERNAL-IP must be a distinct 192.168.105.x per node. Any node showing
  ## 192.168.5.15 means the node-ip pinning failed on that node.
  #
  run_check "node readiness and INTERNAL-IP (expect distinct 192.168.105.x)" \
    "${kc[@]}" get nodes -o wide || failures=$((failures + 1))

  run_check "flannel bound to the right interface (expect --iface=lima0)" \
    "${kc[@]}" -n kube-flannel get daemonset kube-flannel-ds \
    -o jsonpath='{.spec.template.spec.containers[*].args}' || failures=$((failures + 1))

  run_check "all pods across all namespaces" \
    "${kc[@]}" get pods -A -o wide || failures=$((failures + 1))

  run_check "control plane component health" \
    "${kc[@]}" get --raw '/readyz?verbose' || failures=$((failures + 1))

  run_check "coredns availability" \
    "${kc[@]}" -n kube-system get deployment coredns || failures=$((failures + 1))

  run_check "recent warning events" \
    "${kc[@]}" get events -A --field-selector type=Warning \
    --sort-by=.lastTimestamp || failures=$((failures + 1))

  if [ "${failures}" -ne 0 ]
  then
    log "ERROR" "${FUNCNAME[0]}" "${failures} check(s) failed"
    return 1
  fi

  log "INFO" "${FUNCNAME[0]}" "all checks passed"
  return 0
}

show_status() {
  local kubeconfig
  kubeconfig="$(kubeconfig_path)"

  assert_binary "kubectl" "install with: brew install kubectl" || exit 1
  assert_kubeconfig "${kubeconfig}" || exit 1

  run_check "lima instance states" limactl list
  run_check "node summary" kubectl --kubeconfig="${kubeconfig}" get nodes -o wide
  run_check "pod summary" kubectl --kubeconfig="${kubeconfig}" get pods -A
}

show_kubeconfig() {
  echo "export KUBECONFIG=\"$(kubeconfig_path)\""
}

wait_for_coredns() {
  local kubeconfig
  kubeconfig="$(kubeconfig_path)"

  ## cp1 keeps its control-plane taint, so CoreDNS cannot schedule until at
  ## least one worker is Ready. That is why this wait lives here and not in a
  ## template probe.
  #
  log "INFO" "${FUNCNAME[0]}" "waiting for CoreDNS to become available"
  kubectl --kubeconfig="${kubeconfig}" wait -n kube-system \
    --for=condition=available --timeout=300s deploy/coredns
}

do_up() {
  preflight
  start_control_plane
  join_workers
  label_workers
  wait_for_coredns
  log "INFO" "${FUNCNAME[0]}" "cluster up"
  log "INFO" "${FUNCNAME[0]}" "verify with: ./${SCRIPT_NAME} check"
  show_kubeconfig
}

do_down() {
  for instance in ${WORKER_NAMES} ${CP_NAME}
  do
    if instance_exists "${instance}"
    then
      log "INFO" "${FUNCNAME[0]}" "deleting ${instance}"
      limactl delete --force "${instance}"
    fi
  done
}

do_stop() {
  for instance in ${WORKER_NAMES} ${CP_NAME}
  do
    if instance_exists "${instance}"
    then
      log "INFO" "${FUNCNAME[0]}" "stopping ${instance}"
      limactl stop "${instance}" || true
    fi
  done
}

do_start() {
  log "INFO" "${FUNCNAME[0]}" "starting ${CP_NAME}"
  limactl start "${CP_NAME}"
  for worker in ${WORKER_NAMES}
  do
    log "INFO" "${FUNCNAME[0]}" "starting ${worker}"
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
  check)
    run_checks
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
    die "unknown command: ${1}" "main"
    ;;
esac