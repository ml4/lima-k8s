# Three-node kubeadm cluster on Lima

Vagrantfile equivalent: `k8s-node.yaml` is the box definition and provisioner,
`cluster.sh` is `vagrant up` and friends.

## One-time host setup

```bash
brew install lima kubectl
```

socket_vmnet is built from source rather than installed via Homebrew. It is
invoked under sudo, so neither the binary nor any parent directory may be
writable by your user, and the Homebrew prefix is.

```bash
git clone https://github.com/lima-vm/socket_vmnet.git /tmp/socket_vmnet
cd /tmp/socket_vmnet
git checkout v1.2.2
make
sudo make PREFIX=/opt/socket_vmnet install.bin
sudo chmod 755 /opt /opt/socket_vmnet /opt/socket_vmnet/bin
sudo chmod 755 /opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet_client
```

Lima needs to read the sudoers file back, so write it with `install` rather
than `tee` — `tee` leaves it unreadable by your user and `limactl start` fails
with a permission error rather than anything informative.

```bash
limactl sudoers > /tmp/etc_sudoers.d_lima
sudo install -o root -g wheel -m 0644 /tmp/etc_sudoers.d_lima /etc/sudoers.d/lima
sudo visudo -cf /etc/sudoers.d/lima
rm /tmp/etc_sudoers.d_lima
```

Then narrow the socket_vmnet DHCP range so MetalLB has addresses to hand out.
Edit `~/.lima/_config/networks.yaml`, changing the `shared` network's
`dhcpEnd` to `192.168.105.199`, and re-run the two sudoers commands above —
the sudoers rule embeds the daemon's exact argv, so a mismatch makes
socket_vmnet prompt for a password mid-start and the VM times out.

Nodes then take `.2`–`.199` and MetalLB takes `.200`–`.250`. Skip this only if
you never intend to use LoadBalancer services.

## Commands

| Command | What it does |
|---|---|
| `./cluster.sh preflight` | Check the host is ready. Changes nothing. |
| `./cluster.sh up` | Build the cluster. Safe to re-run; reuses what exists. |
| `./cluster.sh check` | Eight verification checks, each command echoed. |
| `./cluster.sh status` | Quick instance, node and pod summary. |
| `./cluster.sh kubeconfig` | Print the `export KUBECONFIG=` line. |
| `./cluster.sh metallb` | Install MetalLB in L2 mode. |
| `./cluster.sh stop` | Stop the VMs, keep the disks. |
| `./cluster.sh start` | Start previously stopped VMs. |
| `./cluster.sh down` | Delete all three VMs. |

## Build

```bash
chmod +x cluster.sh
./cluster.sh preflight
./cluster.sh up
eval "$(./cluster.sh kubeconfig)"
./cluster.sh check
```

Roughly fifteen minutes cold, mostly image pulls. The control plane comes up
first because the workers need its join token. Subsequent builds are faster —
the Ubuntu image and control-plane images are cached.

## Reading the log output

Every line carries a timestamp, a level, and the function that emitted it:

```
2026-08-25 12:16:40 UTC [INFO] [cluster.sh:run_checks] node readiness and INTERNAL-IP
2026-08-25 12:16:40 UTC [CMD]  [cluster.sh:run_checks] kubectl --kubeconfig=... get nodes -o wide
NAME       STATUS   ROLES           INTERNAL-IP
lima-cp1   Ready    control-plane   192.168.105.2
2026-08-25 12:16:40 UTC [OK]   [cluster.sh:run_checks] exit 0
```

| Level | Colour | Meaning |
|---|---|---|
| `INFO` | green | Progress, or what the next check is looking for |
| `CMD` | purple | The exact command about to run — copy-pasteable |
| `OK` | green | That check exited zero |
| `WARN` | yellow | Non-fatal; the build continues |
| `FAIL` | red | That check exited non-zero; others still run |
| `ERROR` | red | Fatal, or an assertion that stopped the run |

The function name matters when something breaks. `[cluster.sh:join_workers]`
versus `[cluster.sh:preflight]` tells you immediately which stage you are in.

Logs go to stderr and command output to stdout, so you can separate them:

```bash
./cluster.sh check 2>/dev/null          # just the command output
./cluster.sh check >/dev/null           # just the log narrative
./cluster.sh check 2>&1 | tee check.log # everything, saved
```

## Using check to diagnose

`check` never modifies anything, so run it freely. Its purpose is that every
command is printed at `CMD` before it runs — when a check looks wrong, copy
that line, run it by hand, and start adding flags.

```bash
eval "$(./cluster.sh kubeconfig)"
./cluster.sh check
```

What each check is really asking:

| Check | Looking for |
|---|---|
| lima instance states | All three `Running`, none `Degraded` |
| api server endpoint | `https://192.168.105.2:6443`, not a `127.0.0.1` forward |
| node readiness and INTERNAL-IP | Three `Ready`, distinct `192.168.105.x` |
| flannel interface | `--iface=lima0` present in the args array |
| all pods | Everything `Running`; CoreDNS on a worker, not cp1 |
| control plane health | Per-component breakdown from `/readyz?verbose` |
| coredns availability | `2/2` ready |
| recent warning events | Background noise, and anything new |

Two of these need a human eye rather than an exit code. The flannel check
prints the full args array and exits zero either way — you have to look for
`--iface=lima0` yourself. And any node showing `192.168.5.15` as its
`INTERNAL-IP` means the node-ip pinning failed on that node; the check will
still pass, because kubectl succeeded.

Expected noise on a healthy cluster: `DNSConfigForming` warnings, because the
guest sees a nameserver on both NICs plus a link-local address and exceeds
kubelet's three-nameserver limit. Also `service account token has expired`
entries after the Mac has slept, which self-heal on wake.

## Assertions

`assert_binary` and `assert_kubeconfig` run before anything that needs them,
and log a remedy rather than just a failure:

```
[ERROR] [cluster.sh:assert_binary] required binary not on PATH: kubectl
[ERROR] [cluster.sh:assert_binary] install with: brew install kubectl

[ERROR] [cluster.sh:assert_kubeconfig] kubeconfig missing or empty: /Users/.../kubeconfig.yaml
[ERROR] [cluster.sh:assert_kubeconfig] is cp1 running? try: ./cluster.sh up
```

The second is the common one and usually means cp1 is stopped or was deleted.
`copyToHost` only populates that file while the control plane is running.

## Day to day

```bash
./cluster.sh stop      # before closing the lid
./cluster.sh start
./cluster.sh check
```

Stop the VMs when you are not using them. VZ does not reliably return guest
memory to macOS, so three idle nodes hold roughly 12 GiB hostage. Leaving them
running through a sleep also expires service account tokens, which is harmless
but fills the event log.

## Optional load balancer

```bash
./cluster.sh metallb
kubectl create deployment nginx --image=nginx:alpine
kubectl expose deployment nginx --type=LoadBalancer --port=80
kubectl get svc nginx
curl "http://$(kubectl get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
```

That `curl` runs on macOS and reaches a VIP inside the cluster directly. This
is the payoff for choosing socket_vmnet over vzNAT. Clean up with
`kubectl delete deployment nginx && kubectl delete svc nginx`.

## Tuning

Everything is an environment variable:

```bash
CP_CPUS=4 CP_MEMORY=8 WORKER_NAMES="w1 w2 w3" ./cluster.sh up
METALLB_RANGE=192.168.105.220-192.168.105.240 ./cluster.sh metallb
METALLB_VERSION=v0.14.9 ./cluster.sh metallb
```

`WORKER_NAMES` must be set consistently across `up`, `down` and `stop`, since
each reads it to know which instances to act on.

## Why the interface pinning matters

Every Lima VM has two NICs. `eth0` is user-mode NAT and is `192.168.5.15` in
all three VMs simultaneously — it exists for outbound traffic and SSH only.
`lima0` is the socket_vmnet shared network and is the only interface with a
unique per-node address.

Three things must therefore be told to use `lima0` rather than the default
route, and all three are wired up in the template:

- `localAPIEndpoint.advertiseAddress`, or the API server advertises an address
  the workers cannot reach
- `kubeletExtraArgs: node-ip`, or all three nodes register the same
  `InternalIP` and pod networking breaks in confusing ways
- flannel's `--iface`, or the CNI builds its mesh over the wrong interface

The `sed` against the flannel manifest is the fragile part — it depends on
`- --kube-subnet-mgr` appearing in the DaemonSet args. If a future flannel
release reorders them, the flannel check in `./cluster.sh check` is how you
find out.

## For CKA practice

`./cluster.sh down && ./cluster.sh up` is a clean cluster in one line, which
matters more than it sounds when you are practising things that break clusters.
Run `./cluster.sh check` after each exercise to confirm you put it back.

Worth doing on this build specifically:

- `etcdctl snapshot save` / `restore` on cp1
- `kubeadm upgrade plan` then `apply`, then `kubeadm upgrade node` on workers
- `kubeadm certs check-expiration` and `renew all`
- drain, cordon, delete and re-join a worker

That last one is handled for you: `up` deletes any stale `lima-<worker>` node
object before creating a worker, because kubeadm refuses to reuse a node name
that already exists in the cluster. It also mints a fresh join token each run,
so the 24-hour default expiry never bites.