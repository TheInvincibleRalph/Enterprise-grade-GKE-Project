# [Part 4] Deploying Cilium: eBPF Networking, WireGuard Encryption, and Hubble Observability.

In Part 3, we deployed the bare infrastructure on Google Cloud. In this part, we will install **Cilium** to replace the current Kubernetes-native datapath with eBPF, encrypt every pod-to-pod packet with WireGuard, and use Hubble to see into the cluster.

---

## Brief Overview.

Cilium is a massive leap forward in the world of networking. To appreciate what Cilium does, we have to understand the nightmare it was built to solve. Imagine you are running a massive, highly dynamic Kubernetes cluster. You have thousands of application containers spinning up to handle traffic spikes, doing their job, and then terminating minutes later. The environment is shifting constantly. It's fluid.

But the underlying plumbing connecting all these workloads relies on architectural concepts that were built for the 1990s internet–legacy Linux components like kube-proxy and iptables. In Linux, when a packet of data hits a network interface, the kernel looks at this predefined list of rules to figure out the packet's fate, like should it be allowed through? Should it be dropped because it's malicious? Does its destination IP address need to be translated before it moves on? All of these are done using iptables. But the bottleneck is how those rules are evaluated. iptables processes packets sequentially; that works for a static website with 10 rules but becomes an Achilles heel in a highly dynamic Kubernetes environment where every new service, every pod, every network policy translates into a barrage of new rules; sometimes hundreds of thousands of them.

And that right there is where Cilium comes in.

Cilium's architecture is a departure from traditional Linux networking, replacing legacy tools like iptables and kube-proxy with a high-performance datapath powered by eBPF (Extended Berkeley Packet Filter). While traditional iptables evaluate rules sequentially (O(N) complexity), which causes performance to degrade as clusters scale; Cilium uses eBPF maps—highly optimized hash tables in the kernel—to perform lookups for routing and policy permissions in constant time (O(1)), maintaining high throughput regardless of the number of services—like it takes the same time to lookup 100,000 rules as it does 10 rules. Massive, innit?

## Core Architectural Components

Cilium is comprised of several core components that work together to manage the cluster's network and security state:

**Cilium Agent:** A per-node daemon (typically a DaemonSet) that acts as the cluster's "brain" on each node. It watches the Kubernetes API for events (Pods, Services, Endpoints) and translates that state into eBPF datapath configurations, compiling and loading the necessary programs into the kernel

**eBPF Datapath:** This is the in-kernel execution layer where packet processing actually occurs
It handles L3/L4 routing, efficient load balancing for Services, and low-overhead policy enforcement

**Cilium Operator:** A cluster-wide controller responsible for duties that require global knowledge, such as synchronizing node IPs, managing IP address allocation (IPAM), and allocating security identities

**Hubble:** The observability layer built on top of Cilium. Since Cilium is bypassing every known Linux native tool; if you bypass netfilter, standard monitoring tools go blind, so you can't just run tcpdump and expect to see the full picture. Hubble exists to bridge that observability gap. It is Cilium's own telescope peering into the deep dark space of the Linux kernel—like NASA's Hubble telescope, but for pods and network packets.

## Let's talk a bit about Encryption before getting our hands dirty.

Kube-proxy, which is the legacy proxy, does not provide native encryption. To secure internal traffic, you must layer a heavy Service Mesh (like Istio using mTLS sidecars) on top, which injects proxy containers into every pod, really increasing memory consumption and latency. But Cilium achieves encryption cleanly inside the Linux kernel. It intercepts packets before they leave the pod network interface and wraps them using either WireGuard (highly optimized, low configuration) or IPsec (hardware-accelerated, enterprise standard). This happens transparently, meaning application code remains completely untouched and no sidecar proxies are needed. We will be using WireGuard in this project.

---

## Step 1 — Install Cilium

```bash
./scripts/install-cilium.sh
```

Under the hood, the script does three things:

```bash
# 1. Add the Helm repo and fetch the charts
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

# 2. Install Cilium 1.16.19 with the project's values file
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.19 \
  --values kubernetes/cilium/values.yaml

# 3. Wait for the datapath, then check its pulse
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
cilium status
```

## The following resources were deployed

1. **Cilium agent** (DaemonSet, `kube-system`) + **cilium-operator**
2. **eBPF datapath** — kube-proxy replacement in the kernel
3. **WireGuard encryption** — transparent pod-to-pod
4. **Hubble Relay + Hubble UI** — flow aggregation and the telescope
5. **Encryption test fixtures** — `test-a`/`test-b` namespaces with netshoot pods

[image]

---

## The following are the important configurations within the installation.

### 5. Tolerations for Taints

Cilium must run everywhere, including the tainted system nodes — so the values file tolerates the `CriticalAddonsOnly` taint. This closes the loop on Part 3's sizing decision: the system pool exists for exactly this kind of workload, and 4 GB per node is the floor that keeps Cilium, CoreDNS, and the operators comfortable.

### 6. Hubble Relay + UI now, Prometheus metrics for later.

Hubble Relay aggregates flows from every agent so the CLI and the UI see the whole cluster, not one node. The UI is the NASA-telescope view from the overview. And `prometheus.enabled: true` is already on — the `serviceMonitor` flips on when Prometheus lands in the observability part, so these eBPF metrics are watched continuously instead of on demand.

---

## Step 2 — Verify the datapath

```bash
cilium status                 # KubeProxyReplacement and Encryption lines
kubectl get pods -n kube-system | grep cilium    # one agent per node + operator
kubectl get ds -n kube-system cilium
```

[image]

Then prove nothing broke — the storefront from Part 4 must still answer:

```bash
curl -H "Host: boutique.invincibledevops.tech" http://<LB_IP>/    # still 200
kubectl get svc -n envoy-gateway-system                            # LB IP unchanged
```

Same 200s, same IP, same routes — now flowing through the eBPF datapath. If you want the full battery, `cilium connectivity test` runs Cilium's own end-to-end validation suite; the smoke test above is what a production engineer actually does first.

## Step 3 — WireGuard: prove the encryption

Encryption you can't see is a checkbox; encryption you can see is a fact. The repo ships two test namespaces with netshoot pods, pinned to the application nodes:

```bash
kubectl apply -f kubernetes/cilium/encryption-test.yaml
kubectl get pods -n test-a -o wide      # note the pod IPs
```

Then the receipt:

```bash
cilium encrypt status     # Encryption: WireGuard | Keys in use: N
```

[image]

And the deeper proof — from inside `netshoot-a`, send HTTP to `netshoot-b`'s pod IP while a node-level `tcpdump` watches the WireGuard interface. You see encrypted packets, not plaintext HTTP, even though the pods themselves are speaking plain HTTP. The full tcpdump walkthrough lives in `docs/deep-dive-why-guide.md`; the short version is:

```bash
sudo tcpdump -i cilium_wg0 -nn port 80    # on the node — encrypted bytes, no plaintext
```





## Step 4 — Our Hubble telescope

Remember why Hubble exists: Cilium bypasses netfilter, so the standard Linux monitoring tools go blind. Hubble is already installed with Cilium (Relay + UI from the values), so all we need is the lens:

```bash
cilium hubble port-forward &        # connect the CLI to the Relay
hubble observe --namespace boutique
```

[image]

And there it is — the storefront's entire social life, visible for the first time:

```text
frontend → cartservice          :2000  (GET /cart)
frontend → productcatalogservice :3550 (ListProducts)
cartservice → redis-cart        :6379  (set cart)
checkoutservice → paymentservice :50051 (Charge)
```

Every east-west call: source, destination, verdict, and latency. When checkout can't reach the cart in a later part, Hubble beats `kubectl logs` — it shows the flow being dropped *before* the app ever sees it.

The UI gets the same view through a port-forward — the cluster is private, so the telescope stays behind the port-forward:

```bash
kubectl port-forward -n kube-system svc/hubble-ui --address 127.0.0.1 12000:80
# then open http://127.0.0.1:12000
```

[image]

One honest note: because our nodes are private, both the CLI and the UI only ever exist on our workstation through port-forwards. You see the telescope; the internet doesn't.

---

## What's next

The inside is encrypted, observable, and O(1) — the cluster is finally a fortress on all sides. But a store with nothing to store isn't a store: every shop, sooner or later, needs a database. In the next part we deploy **HA PostgreSQL on Kubernetes with CloudNativePG** — leader election, synchronous replication, and storage that grows in place. And yes: its replication traffic between zones rides the WireGuard tunnel we just turned on.

---

## Step 3 — WireGuard: prove the encryption

Now let's prove we have our node-to-node encryption intact by applying the encryption test suite.

The test suite ships two test namespaces with netshoot pods. Netshoot is a Docker and Kubernetes network troubleshooting container image. It is loaded with common networking utilities like dig, tcpdump, curl, ping etc to help diagnose cluster or container network.

```bash
kubectl apply -f kubernetes/cilium/encryption-test.yaml
kubectl get pods -n test-a -o wide      # note the pod IPs
kubectl get pods -n test-b -o wide      # and the NODE columns — they must differ
```

**The one precondition:** WireGuard encrypts traffic that crosses between nodes — two pods on the same node never touch the tunnel. If the node columns match, reschedule one:

```bash
kubectl delete pod -n test-b netshoot-b
kubectl get pods -n test-b -o wide      # re-check
```

To prove the encryption we watch one HTTP conversation at three points along its journey. First we need the conversation — three actors:

**1. A listener on B.** Nothing in the test suite actually listens on port 80 — netshoot-b just sleeps:

```bash
kubectl exec -n test-b netshoot-b -- python3 -m http.server 80
```

**2. A sustained flow from A.** One curl is over in milliseconds — too fast for a capture. So from inside netshoot-a, we send HTTP to netshoot-b's pod IP in a loop, one request every half second:

```bash
B_IP=$(kubectl get pod -n test-b netshoot-b -o jsonpath='{.status.podIP}')
kubectl exec -n test-a netshoot-a -- sh -c \
  "while true; do curl -s -o /dev/null http://${B_IP}:80; sleep 0.5; done"
```

The listener must answer properly — that's why it's `python3 -m http.server`, not `nc`: if the server never replies, curl hangs on its first request and the loop stalls. Curl's *responses* don't matter; its *request bytes* are the payload we're watching.

**3. The three captures.** The proof is the same conversation seen at three points:

```bash
# Point 1 — at the pod's own interface, the request in plaintext:
kubectl exec -n test-a netshoot-a -- tcpdump -i eth0 -nn -c 20 -A port 80
```

```text
14:32:04.810752 IP 10.1.4.169.37526 > 10.1.5.245.80: Flags [P.], seq 1:75, ... length 74: HTTP: GET / HTTP/1.1
GET / HTTP/1.1
Host: 10.1.5.245
User-Agent: curl/8.21.0
```

Readable, plain text. Now move to the node — and here comes the first surprise: on the WireGuard interface itself, we *still* see plaintext. That's because WireGuard encrypts **inside** the interface, and tcpdump taps the interface before the encryption happens:

```bash
# Point 2 — the node's WireGuard interface (same plaintext, about to be wrapped):
NODE_A=$(kubectl get pod -n test-a netshoot-a -o jsonpath='{.spec.nodeName}')
kubectl debug node/${NODE_A} -it --image=nicolaka/netshoot -- tcpdump -i cilium_wg0 -nn -c 20 -A
```

```text
14:42:18.806782 IP 10.1.4.169.56064 > 10.1.5.245.80: Flags [P.], seq 1:75, ... length 74: HTTP: GET / HTTP/1.1
GET / HTTP/1.1
Host: 10.1.5.245
```

Then the receipt — the same flow on the node's physical NIC, after the packet has crossed the WireGuard device:

```bash
# Point 3 — the node's physical interface, where the envelope is on the wire:
kubectl debug node/${NODE_A} -it --image=nicolaka/netshoot -- tcpdump -i eth0 -nn -c 20 'udp port 51871'
```

```text
14:50:09.346074 IP 10.0.0.24.51871 > 10.0.0.15.51871: UDP, length 96
14:50:09.348634 IP 10.0.0.15.51871 > 10.0.0.24.51871: UDP, length 464
14:50:09.348918 IP 10.0.0.24.51871 > 10.0.0.15.51871: UDP, length 96
```

**So where does the encryption actually happen?** At the WireGuard device inside the node's kernel. A packet enters `cilium_wg0` as the plaintext pod-to-pod packet we saw at Point 2, and the device wraps it — in the kernel, in microseconds — into a UDP datagram addressed *node-to-node* on port 51871, encrypted with the session key the two nodes agreed in their WireGuard handshake. By Point 3 the payload is opaque: no TCP, no HTTP, nothing readable. The 464-byte datagrams are our 373-byte HTML response plus headers and encryption overhead, and the bursts arrive every half second, exactly when curl fires. Same conversation, three views: **plaintext at the pod, plaintext at the tunnel mouth, ciphertext on the wire.**

And the config-level receipt, which shows the feature is on cluster-wide:

```bash
cilium encrypt status     # Encryption: WireGuard | Keys in use: N
```

**The integrity check (worth doing once):** `cilium encrypt disable`, re-run the Point 3 capture — you'll see plaintext `GET / HTTP/1.1` on the node's eth0. `cilium encrypt enable`, re-run it — opaque UDP again. That before/after is the cleanest possible proof of where the protection lives.
