# Configuring the Cluster's Edge: Envoy Gateway with an In-Process Coraza WAF

Part 4 of the series. In Part 3 we provisioned the private, multi-zone GKE cluster: six spot nodes across three zones, no public IPs, kubectl pointing at it. But a private cluster with nothing listening is just an expensive study hall. In this part we build the **edge**: the single public door to the cluster — one LoadBalancer IP, routing done the modern way (Gateway API), and a Web Application Firewall that runs *inside* the proxy's own process.

---

## Why Envoy Gateway?

If you have worked with Kubernetes before, you know the classic choice for a proxy was the NGINX Ingress Controller, but it has been retired and now we have to use something else.

Envoy Gateway is the actively maintained successor, and it is built around the **Gateway API**.

According to the Gateway API standard routing is declared as four objects (GatewayClass → Gateway → HTTPRoute → Service). Envoy Gateway implements this standard and gives room for some extensions, which we would see later.

---

## Request Flow

Before we go into the weeds Evoy terminologies, let's take a look at our architecture and get a glimpse of how traffic flows inside our cluster.

**1. Traffic (the data plane):**

```
Browser → Cloudflare → GCP Load Balancer → Envoy (WAF + routing) → Boutique frontend → microservices
```

- Cloudflare handles the HTTPS, and sends plain HTTP to the load balancer.
- The load balancer forwards to one of the three Envoy pods.
- Inside that Envoy pod, three things happen in order: the **listener** accepts the request, the **WAF** checks it, and the **router** sends it to the frontend.
- Then the frontend calls the other microservices on the backend.

The function of the Envoy Gateway Controller is to read our YAML (Gateway, HTTPRoute, WAF policy), turns it into Envoy's config language, and pushes it to the Envoy pods.


## Envoy vs Envoy Gateway: the worker and the manager

Before we go further, let's settle the two names at the center of this entire architecture.

In simple terms, the difference between Envoy (often called Envoy Proxy) and Envoy Gateway is their role in managing network traffic: **Envoy is the "worker" that moves the data, while Envoy Gateway is the "manager" that tells it how to do its job.**

Here is a breakdown of the differences:

**1. The "Worker" (Envoy Proxy)**

Envoy Proxy is high-performance, open-source network proxy. It sits in the "data plane," meaning it actually handles the live traffic. It receives requests, terminates TLS encryption, performs load balancing, and forwards traffic to your backend services. But configuring Envoy directly is notoriously difficult and requires deep networking expertise. A single configuration can easily reach 20,000 lines of complex code.

**2. The "Manager" (Envoy Gateway)**

Envoy Gateway is a Kubernetes-native "control plane" built to manage Envoy. It orchestrates and configures Envoy instances. It watches simple Kubernetes commands (using the Gateway API standard) and automatically translates them into the complex instructions Envoy understands. It manages the lifecycle of Envoy, meaning it can automatically provision, update, and scale the Envoy "worker" pods for you.


### Where every Envoy term lives in this project

Each of these terms is about to appear in the resources we deploy, so here is what each one is, and what it does in *this* architecture.

**Data plane / control plane** — the two-layer model behind the worker/manager split. The data plane is where traffic actually flows; the control plane is the brain that decides how it flows. In this project: the data plane is the three Envoy pods behind the GCP load balancer (one per AZ — the replicas you'll see after the install); the control plane is the Envoy Gateway controller pod in `envoy-gateway-system`, which never sees a single request.

**Envoy (the proxy)** — the data-plane worker. It receives requests, terminates TLS (in the general case), load-balances, and forwards traffic to backend services; in this project it also runs the WAF inside its own process. In this project: the three Envoy pods that form the `boutique-gateway` deployment. Every request — storefront page or SQL injection — passes through one of them. One honest note: TLS termination isn't Envoy's job *here*; Cloudflare owns TLS and forwards plain HTTP to the gateway (the Flexible SSL decision in Part 5). The engine is real; we just don't hand it the keys it doesn't need.

**Envoy Gateway** — the control-plane manager. It watches Gateway API resources, translates them into Envoy's low-level config, and pushes it to the worker pods over xDS — no reloads, no restarts. It also provisions and scales the Envoy pods themselves. In this project: the controller in `envoy-gateway-system`. It's the component that turned our four YAML files into running pods, a load balancer, and an `Accepted` gateway — and the reason `kubectl get gateway` tells us the door is open.

**Gateway API** — the vendor-neutral Kubernetes standard for L4/L7 routing (SIG-Network's replacement for Ingress). Routes are declared as objects, and any implementation that honors the standard can serve them. In this project: all four resources we apply are Gateway API objects — which means the same YAML would work against Istio, Kong, or Traefik if we ever swapped implementations. The standard is the portability; Envoy Gateway is the implementation.

**GatewayClass (`eg`)** — the contract between "I want a gateway" and "which gateway, configured how?" It names the controller (Envoy Gateway) and points at the customization that shapes the data plane (the EnvoyProxy). In this project: `gatewayclass.yaml` — the top of the hierarchy, applied exactly once.

**Gateway (`boutique-gateway`)** — the front door: the concrete listener (HTTP on :80), and through the class, the actual Envoy deployment and its load balancer. In this project: the resource that produced the GCP LoadBalancer IP — the address Cloudflare's A record points at in Part 5.

**HTTPRoute (`boutique-route`)** — the routing rule: hostname + path → backend service. The Gateway is the door; the HTTPRoute is the sign telling each visitor which room they're allowed into. In this project: `boutique.invincibledevops.tech /` → `frontend:80`, living in the `boutique` namespace while the door lives in `envoy-gateway-system`.

**EnvoyProxy (`envoy-proxy`)** — Envoy Gateway's own customization resource: it describes how the Envoy worker pods are built. In this project: the file that mounts the Coraza `.so` into every Envoy pod via an image volume and sets `GODEBUG=cgocheck=0` — the reason the WAF runs in-process, and the reason the cluster needed 1.35+ (the `min_master_version` floor from Part 3).

**EnvoyExtensionPolicy (`waf-extension`)** — the resource that attaches an extension filter (here: Coraza) to a Gateway, so every route through it inherits the filter. In this project: the OWASP CRS directives — and the file whose deletion makes the 403s stop (the integrity proof in Part 5).

**Dynamic module** — a native shared library (`.so`) loaded directly into the Envoy process. The WAF is not a sidecar and not a separate proxy; it is Envoy. In this project: `libcomposer.so` served from the composer image, loaded as the `coraza-waf` filter. Every 403 in the verification section is this module's work.

**xDS** — the protocol Envoy Gateway uses to deliver configuration to Envoy workers ("x" stands for any of the discovery services: listener, route, cluster, and friends). Config changes flow through xDS at runtime — which is why updating an HTTPRoute doesn't restart a single pod. In this project: the invisible pipeline between the controller and the three Envoy pods. You'll never touch it directly, and you'll benefit from it every time a route changes without a blip.

---


---

## Step 1 — Install Envoy Gateway

```bash
./scripts/install-envoy-gateway.sh
```

Under the hood, the script does three things:

```bash
# 1. Render the chart locally — helm template never touches the cluster
helm template eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.3 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --timeout 10m \
  --output-dir /tmp/eg-manifests

# 2. Apply the rendered manifests — validate=false avoids the OpenAPI download
find /tmp/eg-manifests -type f -name '*.yaml' -print0 | sort -z | \
  xargs -0 -n1 kubectl apply --validate=false -f

# 3. Apply our Gateway API resources, then wait for acceptance and the LB IP
kubectl apply -f kubernetes/gateway/gatewayclass.yaml
kubectl apply -f kubernetes/gateway/envoyproxy.yaml
kubectl apply -f kubernetes/gateway/gateway.yaml
kubectl apply -f kubernetes/gateway/waf-extensionpolicy.yaml
kubectl wait --for=condition=Accepted gateway/boutique-gateway -n envoy-gateway-system --timeout=120s
```

The chart ships the Gateway API CRDs, so the `GatewayClass`/`HTTPRoute` objects have a home the moment the install finishes.


The script then watches for the LoadBalancer IP (2–5 minutes) and prints it, with the next step:

[image]

---

## To understand what the config achieves, I will highlight important decisions or 'settings' that shaped our edge.

  


---

## Step 2 — Deploy the app the WAF protects

A WAF with no traffic is a theory. Let's give it something to guard:

```bash
BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh
```

The script creates the `boutique` namespace, pulls the upstream Online Boutique manifests (Google's microservices-demo), waits for the frontend to roll out, and applies the HTTPRoute with your real hostname substituted in.

```bash
kubectl get pods -n boutique            # frontend + microservices Running
kubectl get httproute -n boutique       # Accepted=True
```

[image]

## Step 3 — The 403s that prove it

First prove the happy path:

```bash
# Straight at the LoadBalancer, host header doing the routing
curl -H "Host: boutique.invincibledevops.tech" http://<LB_IP>/      # expect 200

# Through Cloudflare once DNS propagates (1-2 min)
curl -I https://boutique.invincibledevops.tech
```

Then the part that makes it all real — a SQL injection that would melt an unprotected app:

```bash
curl -H "Host: boutique.invincibledevops.tech" \
  "http://<LB_IP>/?id=1'+OR+'1'='1"     # expect 403
```

Same gateway, same route, same cluster — the only difference is the request content. The OWASP CRS rule fired, and the request never reached the application.

For the full tour, the test script throws the five classic attack classes at the `/search` endpoint:

```bash
./scripts/waf-test.sh https://boutique.invincibledevops.tech
```

| Payload | Attack class |
|---|---|
| `1' OR '1'='1` | SQL injection |
| `<script>alert('xss')</script>` | Stored XSS |
| `../../../etc/passwd` | Path traversal |
| `; cat /etc/passwd` | Command injection |
| `' UNION SELECT * FROM users--` | UNION-based SQL injection |

```
==> Testing WAF at https://boutique.invincibledevops.tech

Testing: 1' OR '1'='1 ... blocked (403)
Testing: <script>alert('xss')</script> ... blocked (403)
Testing: ../../../etc/passwd ... blocked (403)
Testing: ; cat /etc/passwd ... blocked (403)
Testing: ' UNION SELECT * FROM users-- ... blocked (403)

==> Results: 5/5 attacks blocked
WAF appears to be working correctly
```

[image]

5/5, and the receipts are in the logs:

```bash
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway \
  | grep -i -E 'coraza|denied'
```

If a payload ever slips through, that grep is where you start — and the first suspect is that `EnvoyExtensionPolicy` file.

---

## What's next

The front door is guarded, but the hallway is still vanilla. In the next part we make the inside as secure as the entrance: **Cilium** — the eBPF dataplane that replaces kube-proxy, enforces NetworkPolicies, and encrypts every pod-to-pod packet with WireGuard. The WAF keeps the bad requests out; WireGuard makes the traffic they'd eavesdrop on unreadable anyway.
