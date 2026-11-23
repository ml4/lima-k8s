#!/usr/bin/env bash
#
# cluster.sh - reproducible multi-cluster kubeadm labs on Lima + socket_vmnet.
#
# Usage: ./cluster.sh <command> [cluster]
#
#   ./cluster.sh up a          build cluster a
#   ./cluster.sh up b          build cluster b alongside it
#   ./cluster.sh check a       verification checks for cluster a
#   ./cluster.sh list          every instance across every cluster
#   ./cluster.sh down b        delete cluster b only
#   ./cluster.sh nuke          delete every cluster and clear runtime state
#
# Cluster defaults to "a" when omitted.

set -euo pipefail

## socket_vmnet runs under sudo but inherits the caller's umask. With a
## restrictive umask (077) its pid file and socket land 0600 root:wheel and
## limactl, running as you, cannot read them back.
#
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
TEMPLATE="${SCRIPT_DIR}/k8s-node.yaml"

## Every cluster this script knows about. nuke and list iterate this.
#
KNOWN_CLUSTERS="${KNOWN_CLUSTERS:-a b}"

## Workshop defaults: two k8s clusters must coexist on a 32GiB Mac without
## swapping. kubeadm hard-requires 2 vCPU on the control plane; workers are fine
## on 1. Override for CKA practice: WORKER_SUFFIXES="w1 w2" WORKER_MEMORY=4
#
CP_SUFFIX="${CP_SUFFIX:-cp1}"
WORKER_SUFFIXES="${WORKER_SUFFIXES:-w1}"
CP_CPUS="${CP_CPUS:-2}"
CP_MEMORY="${CP_MEMORY:-3}"
WORKER_CPUS="${WORKER_CPUS:-1}"
WORKER_MEMORY="${WORKER_MEMORY:-2}"

## Warn when the host is close to swapping. VZ does not reliably hand guest
## memory back to macOS, so pressure only ever accumulates.
#
MEM_FREE_WARN_PCT="${MEM_FREE_WARN_PCT:-30}"
SWAP_USED_WARN_MB="${SWAP_USED_WARN_MB:-512}"

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
## cluster_config
## Resolve every per-cluster value from the cluster letter. Two clusters share
## the 192.168.105.0/24 segment, so pod subnets, VXLAN VNIs and MetalLB pools
## must not overlap.
#
function cluster_config {
  CLUSTER="${1}"

  case "${CLUSTER}" in
    a)
      POD_SUBNET="10.244.0.0/16"
      VNI="1"
      METALLB_RANGE="${METALLB_RANGE_A:-192.168.105.200-192.168.105.224}"
      ;;
    b)
      POD_SUBNET="10.245.0.0/16"
      VNI="2"
      METALLB_RANGE="${METALLB_RANGE_B:-192.168.105.225-192.168.105.249}"
      ;;
    *)
      die "unknown cluster '${CLUSTER}'; known clusters: ${KNOWN_CLUSTERS}" "${FUNCNAME[0]}"
      ;;
  esac

  SERVICE_SUBNET="10.96.0.0/12"
  CP_NAME="${CLUSTER}-${CP_SUFFIX}"

  WORKER_NAMES=""
  for suffix in ${WORKER_SUFFIXES}
  do
    WORKER_NAMES="${WORKER_NAMES} ${CLUSTER}-${suffix}"
  done
  WORKER_NAMES="$(echo "${WORKER_NAMES}" | xargs)"

  log "INFO" "${FUNCNAME[0]}" "cluster ${CLUSTER}: cp=${CP_NAME} workers=[${WORKER_NAMES}] pods=${POD_SUBNET} vni=${VNI}"
}

##################################################################################################################################################
## check_host_memory
## macOS reports differently to Linux: "used" includes purgeable cache, so the
## meaningful signals are free percentage and swap consumption, not free RAM.
#
function check_host_memory {
  local free_pct swap_used

  free_pct="$(memory_pressure 2>/dev/null | awk -F': *' '/free percentage/ {gsub(/%/,"",$2); print $2}')"
  swap_used="$(sysctl -n vm.swapusage 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="used") {gsub(/M/,"",$(i+2)); print $(i+2)}}')"

  if [ -n "${free_pct}" ]
  then
    if [ "${free_pct%%.*}" -lt "${MEM_FREE_WARN_PCT}" ]
    then
      log "WARN" "${FUNCNAME[0]}" "host memory free ${free_pct}% (below ${MEM_FREE_WARN_PCT}%)"
    else
      log "INFO" "${FUNCNAME[0]}" "host memory free ${free_pct}%"
    fi
  fi

  if [ -n "${swap_used}" ]
  then
    if [ "${swap_used%%.*}" -gt "${SWAP_USED_WARN_MB}" ]
    then
      log "WARN" "${FUNCNAME[0]}" "swap in use: ${swap_used}MB — stop unused VMs before building more"
      log "WARN" "${FUNCNAME[0]}" "check: limactl list; limactl stop <name>"
    else
      log "INFO" "${FUNCNAME[0]}" "swap in use: ${swap_used}MB"
    fi
  fi
}

##################################################################################################################################################
## assert_binary
## fail early and loudly if a required binary is not on PATH
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
## fail early if the control plane kubeconfig has not been copied to the host
#
function assert_kubeconfig {
  local -r kubeconfig="${1}"

  if [ ! -s "${kubeconfig}" ]
  then
    log "ERROR" "${FUNCNAME[0]}" "kubeconfig missing or empty: ${kubeconfig}"
    log "ERROR" "${FUNCNAME[0]}" "is ${CP_NAME} running? try: ./${SCRIPT_NAME} up ${CLUSTER}"
    return 1
  fi

  log "INFO" "${FUNCNAME[0]}" "using kubeconfig ${kubeconfig}"
  return 0
}

##################################################################################################################################################
## run_check
## echo the command at CMD level so it can be re-run by hand, then run it and
## print the output verbatim
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
  ##
  ## The listing is captured before matching rather than piped into grep -q:
  ## under `set -o pipefail`, grep exiting early on a match SIGPIPEs limactl and
  ## the pipeline returns 141, so the function intermittently reported existing
  ## instances as absent.
  #
  local names
  names="$(limactl list --format '{{.Name}}' 2>/dev/null || true)"
  if grep -qx "${1}" <<< "${names}"
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

  if [ ! -x /opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet ] \
    && [ ! -x /usr/local/opt/socket_vmnet/bin/socket_vmnet ]
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
      log "WARN" "${FUNCNAME[0]}" "run: ./${SCRIPT_NAME} nuke"
    fi
  fi

  if [ ! -f "${TEMPLATE}" ]
  then
    die "template not found: ${TEMPLATE}" "${FUNCNAME[0]}"
  fi

  ## Each k8s cluster costs CP_MEMORY + (workers x WORKER_MEMORY) GiB.
  #
  local running total
  running="$(limactl list --format '{{.Name}}' 2>/dev/null | wc -l | xargs)"
  total=$(( CP_MEMORY + $(echo "${WORKER_SUFFIXES}" | wc -w | xargs) * WORKER_MEMORY ))
  log "INFO" "${FUNCNAME[0]}" "${running} lima instance(s) exist; cluster ${CLUSTER} will use ${total}GiB"
  check_host_memory

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

  log "INFO" "${FUNCNAME[0]}" "creating control plane ${CP_NAME} (${CP_CPUS} vCPU, ${CP_MEMORY}GiB, pods ${POD_SUBNET}, vni ${VNI})"
  limactl start \
    --name="${CP_NAME}" \
    --cpus="${CP_CPUS}" \
    --memory="${CP_MEMORY}" \
    --tty=false \
    --param podSubnet="${POD_SUBNET}" \
    --param serviceSubnet="${SERVICE_SUBNET}" \
    --param vni="${VNI}" \
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
      --param podSubnet="${POD_SUBNET}" \
      --param serviceSubnet="${SERVICE_SUBNET}" \
      --param vni="${VNI}" \
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

wait_for_coredns() {
  local kubeconfig
  kubeconfig="$(kubeconfig_path)"

  ## The control plane keeps its taint, so CoreDNS cannot schedule until at
  ## least one worker is Ready. That is why this wait lives here and not in a
  ## template probe.
  #
  log "INFO" "${FUNCNAME[0]}" "waiting for CoreDNS to become available"
  kubectl --kubeconfig="${kubeconfig}" wait -n kube-system \
    --for=condition=available --timeout=300s deploy/coredns
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

  log "INFO" "${FUNCNAME[0]}" "installing MetalLB ${version} on cluster ${CLUSTER}"
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
  name: lima-pool-${CLUSTER}
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lima-l2-${CLUSTER}
  namespace: metallb-system
spec:
  ipAddressPools:
  - lima-pool-${CLUSTER}
EOF
  log "INFO" "${FUNCNAME[0]}" "cluster ${CLUSTER} LoadBalancer VIPs come from ${METALLB_RANGE}"
}

##################################################################################################################################################
## run_checks
## post-build verification. Every command is echoed at CMD level so it can be
## pasted straight into a shell when a check needs digging into.
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

  ## Two clusters on one L2 segment must not share a pod subnet or a VNI.
  #
  run_check "flannel net-conf (expect Network ${POD_SUBNET}, VNI ${VNI})" \
    "${kc[@]}" -n kube-flannel get configmap kube-flannel-cfg \
    -o jsonpath='{.data.net-conf\.json}' || failures=$((failures + 1))

  run_check "service account issuer, the JWT auth trust anchor" \
    "${kc[@]}" get --raw /.well-known/openid-configuration || failures=$((failures + 1))

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
    log "ERROR" "${FUNCNAME[0]}" "${failures} check(s) failed on cluster ${CLUSTER}"
    return 1
  fi

  log "INFO" "${FUNCNAME[0]}" "all checks passed on cluster ${CLUSTER}"
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

##################################################################################################################################################
## show_sapub
## Print the control plane's service account signing public key, which is what
## Vault's JWT auth method needs in jwt_validation_pubkeys.
#
function show_sapub {
  log "INFO" "${FUNCNAME[0]}" "service account signing public key for cluster ${CLUSTER}"
  log "CMD" "${FUNCNAME[0]}" "limactl shell ${CP_NAME} sudo cat /etc/kubernetes/pki/sa.pub"
  limactl shell "${CP_NAME}" sudo cat /etc/kubernetes/pki/sa.pub
}

##################################################################################################################################################
## list_all
## Every instance this script knows about, across every cluster.
#
function list_all {
  assert_binary "limactl" "install with: brew install lima" || exit 1

  run_check "all lima instances" limactl list || true

  for cluster in ${KNOWN_CLUSTERS}
  do
    local cp="${cluster}-${CP_SUFFIX}"
    if instance_exists "${cp}"
    then
      log "INFO" "${FUNCNAME[0]}" "cluster ${cluster}: present"
    else
      log "INFO" "${FUNCNAME[0]}" "cluster ${cluster}: absent"
    fi
  done
}

do_up() {
  preflight
  start_control_plane
  join_workers
  label_workers
  wait_for_coredns
  log "INFO" "${FUNCNAME[0]}" "cluster ${CLUSTER} up"
  log "INFO" "${FUNCNAME[0]}" "verify with: ./${SCRIPT_NAME} check ${CLUSTER}"
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
  log "INFO" "${FUNCNAME[0]}" "cluster ${CLUSTER} deleted"
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

##################################################################################################################################################
## do_nuke
## Delete every known cluster and clear socket_vmnet runtime state. Destructive
## and irreversible, so it asks first unless NUKE_YES=1.
#
function do_nuke {
  local targets=""

  for cluster in ${KNOWN_CLUSTERS}
  do
    for instance in "${cluster}-${CP_SUFFIX}" $(for s in ${WORKER_SUFFIXES}; do echo "${cluster}-${s}"; done)
    do
      if instance_exists "${instance}"
      then
        targets="${targets} ${instance}"
      fi
    done
  done
  targets="$(echo "${targets}" | xargs)"

  if [ -z "${targets}" ]
  then
    log "INFO" "${FUNCNAME[0]}" "no known cluster instances to delete"
  else
    log "WARN" "${FUNCNAME[0]}" "about to permanently delete: ${targets}"
  fi
  log "WARN" "${FUNCNAME[0]}" "and clear /private/var/run/lima (needs sudo)"

  ## Anything not created by this script is left alone, so say so.
  #
  local strays
  local all_names
  all_names="$(limactl list --format '{{.Name}}' 2>/dev/null || true)"
  strays="$(grep -vE "^($(echo "${targets}" | tr ' ' '|'))$" <<< "${all_names}" || true)"
  if [ -n "${strays}" ] && [ -n "${targets}" ]
  then
    log "WARN" "${FUNCNAME[0]}" "leaving other instances untouched: $(echo "${strays}" | xargs)"
  fi

  if [ "${NUKE_YES:-0}" != "1" ]
  then
    read -r -p "Type 'nuke' to confirm: " reply
    if [ "${reply}" != "nuke" ]
    then
      die "aborted" "${FUNCNAME[0]}"
    fi
  fi

  for instance in ${targets}
  do
    log "INFO" "${FUNCNAME[0]}" "deleting ${instance}"
    limactl delete --force "${instance}" || true
  done

  log "INFO" "${FUNCNAME[0]}" "stopping socket_vmnet and clearing runtime state"
  sudo pkill -f socket_vmnet || true
  sudo rm -rf /private/var/run/lima
  log "INFO" "${FUNCNAME[0]}" "done; run ./${SCRIPT_NAME} preflight before rebuilding"
}

##################################################################################################################################################
## main
#
COMMAND="${1:-up}"
CLUSTER_ARG="${2:-a}"

case "${COMMAND}" in
  list)
    list_all
    ;;
  mem)
    check_host_memory
    ;;
  nuke)
    do_nuke
    ;;
  up)
    cluster_config "${CLUSTER_ARG}"
    do_up
    ;;
  down)
    cluster_config "${CLUSTER_ARG}"
    do_down
    ;;
  stop)
    cluster_config "${CLUSTER_ARG}"
    do_stop
    ;;
  start)
    cluster_config "${CLUSTER_ARG}"
    do_start
    ;;
  status)
    cluster_config "${CLUSTER_ARG}"
    show_status
    ;;
  check)
    cluster_config "${CLUSTER_ARG}"
    run_checks
    ;;
  kubeconfig)
    cluster_config "${CLUSTER_ARG}" >/dev/null 2>&1
    show_kubeconfig
    ;;
  sapub)
    cluster_config "${CLUSTER_ARG}" >/dev/null 2>&1
    show_sapub
    ;;
  metallb)
    cluster_config "${CLUSTER_ARG}"
    install_metallb
    ;;
  preflight)
    cluster_config "${CLUSTER_ARG}"
    preflight
    ;;
  *)
    die "unknown command: ${COMMAND}" "main"
    ;;
esac