# Three-node kubeadm cluster on Lima

Vagrantfile equivalent: `k8s-node.yaml` is the box definition and provisioner,
`cluster.sh` is `vagrant up` and friends.

## One-time host setup

```bash
brew install lima socket_vmnet kubectl
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

Then narrow the socket_vmnet DHCP range so MetalLB has addresses to hand out.
Edit `~/.lima/_config/networks.yaml` and change the `shared` network:

```yaml
networks:
  shared:
    mode: shared
    gateway: 192.168.105.1
    dhcpEnd: 192.168.105.199
    netmask: 255.255.255.0
```

Nodes take `.2`–`.199`, MetalLB takes `.200`–`.250`. Skip this only if you
never intend to use LoadBalancer services.

## Build

```bash
chmod +x cluster.sh
./cluster.sh preflight
./cluster.sh up
eval "$(./cluster.sh kubeconfig)"
kubectl get nodes -o wide
```

Roughly fifteen minutes cold, mostly image pulls. The control plane comes up
first because the workers need its join token.

## Optional load balancer

```bash
./cluster.sh metallb
kubectl create deployment nginx --image=nginx:alpine
kubectl expose deployment nginx --type=LoadBalancer --port=80
kubectl get svc nginx
```

The `EXTERNAL-IP` is reachable from macOS directly. This is the payoff for
choosing socket_vmnet over vzNAT.

## Day to day

```bash
./cluster.sh stop      # before closing the lid
./cluster.sh start
./cluster.sh status
./cluster.sh down      # full teardown
```

Stop the VMs when you are not using them. VZ does not reliably return guest
memory to macOS, so three idle nodes hold roughly 12 GiB hostage.

## Tuning

Everything is an environment variable:

```bash
CP_CPUS=4 CP_MEMORY=8 WORKER_NAMES="w1 w2 w3" ./cluster.sh up
```

## Why the interface pinning matters

Every Lima VM has two NICs. `eth0` is user-mode NAT and is `192.168.5.15` in
all three VMs simultaneously — it exists for outbound traffic and SSH only.
`lima0` is the socket_vmnet shared network and is the only interface with a
unique per-node address.

Three things must therefore be told to use `lima0` rather than the default
route, and all three are wired up in the template:

- `localAPIEndpoint.advertiseAddress`, or the API server advertises an address
  the workers cannot reach
- `kubeletExtraArgs: node-ip`, or all three nodes register the same `InternalIP`
  and pod networking breaks in confusing ways
- flannel's `--iface`, or the CNI builds its mesh over the wrong interface

The `sed` against the flannel manifest is the fragile part. If a future flannel
release reorders its container args, check that `--iface=lima0` actually landed:

```bash
kubectl -n kube-flannel get ds kube-flannel-ds -o yaml | grep iface
```

## For CKA practice

`./cluster.sh down && ./cluster.sh up` is a clean cluster in one line, which
matters more than it sounds when you are practising things that break clusters.
Worth doing on this build specifically:

- `etcdctl snapshot save` / `restore` on cp1
- `kubeadm upgrade plan` then `apply`, then `kubeadm upgrade node` on workers
- `kubeadm certs check-expiration` and `renew all`
- drain, cordon, delete and re-join a worker with a fresh token

The token from `kubeadm token create --print-join-command` expires after 24
hours by default. `cluster.sh` mints a fresh one on every `up`, so a rebuilt
worker joins cleanly.
