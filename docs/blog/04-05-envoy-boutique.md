# Configuring the Cluster's Edge: Envoy Gateway with an In-Process Coraza WAF & Deploying a Microservices Application Behind the Web Application Firewall.

Part 4 of the series. In Part 3 we provisioned the private, multi-zone GKE cluster. In this part we will configure the cluster's edge and deploy **Google's Online Boutique**, and prove that our live infrastructure is attack-proof.

---

## Why Envoy Gateway?

If you have worked with Kubernetes before, you know the classic choice for a proxy was the NGINX Ingress Controller, but it has been retired and now we have to use something else.

Envoy Gateway is the actively maintained successor, and it is built around the **Gateway API**.

According to the Gateway API standard, routing is declared as four objects (GatewayClass → Gateway → HTTPRoute → Service). Envoy Gateway implements this standard and gives room for some extensions, which we would see later.

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


## Components of our Envoy Setup

**1. The "Worker" (Envoy Proxy)**

Envoy Proxy is high-performance, open-source network proxy. It sits in the "data plane," meaning it actually handles the live traffic. It receives requests, terminates TLS encryption, performs load balancing, and forwards traffic to backend services. But configuring Envoy directly is notoriously difficult and requires deep networking expertise. A single configuration can easily reach 20,000 lines of complex code. That is where the Envoy Gateway chimes in.

**2. The "Manager" (Envoy Gateway)**

Envoy Gateway is a Kubernetes-native "control plane" built to manage Envoy. It orchestrates and configures Envoy instances. It watches simple Kubernetes commands (using the Gateway API standard) and automatically translates them into the complex instructions Envoy understands. It manages the lifecycle of Envoy, meaning it can automatically provision, update, and scale Envoy worker pods.

## These are the files that make up our deployment
**3. GatewayClass (`eg`)**: This is just a template that defines a specific type of network load balancer or proxy to be implemeted within a cluster.

**Gateway (`boutique-gateway`)**: This is the actual, running instance of Envoy deployment and its loadbalancer. It listens on port 80.

**HTTPRoute (`boutique-route`)**: This is a set of rules that define how HTTP traffic coming into a Gateway gets sent to the backend services.

**EnvoyProxy (`envoy-proxy`)**: It describes how the Envoy worker pods are built. 

**EnvoyExtensionPolicy (`waf-extension`)**: the resource that attaches an extension filter (here: Coraza) to a Gateway, so every route through it inherits the filter.


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

# 2. Apply the rendered manifests
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

## Deploying a Microservices Application Behind a WAF

[image]

We will be deploying Online Boutique; Google's official microservices-demo which is a full e-commerce application built to show what real microservices look like: many different pods, all speaking to each other over the network.

It is the perfect application for this cluster, for two reasons:

1. **It is microservice-shaped.** Dozens of pods, real inter-service calls, and a stateful cache.

2. **It gives the WAF a real target.** A working storefront with a search endpoint, query parameters, and forms is exactly the attack surface a production app has.
---

## The following resources were deployed

1. **Namespace `boutique`**
2. **Online Boutique** (frontend + 11 microservices + redis-cart)
3. **HTTPRoute `boutique-route`** — the app's contract with the edge.
4. **Cloudflare** — A record + Flexible SSL: HTTPS to the world, plain HTTP to the origin

## Step 2 — Deploy the application

The cluster's edge is already live from Step 1 — the Gateway is accepted and the LoadBalancer has an IP. Deploying the storefront is one command:

```bash
BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh
```

Under the hood, the script does three jobs:

```bash
# 1. The app's namespace
kubectl apply -f kubernetes/boutique/namespace.yaml

# 2. The app itself, straight from Google's repo
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml -n boutique

# 3. The route
sed "s/boutique.example.dev/${BOUTIQUE_HOST}/" kubernetes/gateway/httproute.yaml | kubectl apply -f -
```

The script waits for the frontend to roll out, then shows the deployed resources.

```bash
kubectl rollout status deployment/frontend -n boutique --timeout=5m
kubectl get pods,svc -n boutique
kubectl get httproute -n boutique
```

[image]

You should see a grid of Running pods — `frontend`, `cartservice`, `productcatalogservice`, `checkoutservice`, plus `redis-cart`, and the HTTPRoute reporting **Accepted=True**. Accepted means the Gateway API agreed with our route: the edge at `envoy-gateway-system` is willing to route this app's hostname.

---

One things worth noticing. First, **the route lives in a different namespace than the gateway** — `boutique` vs `envoy-gateway-system`, this is because cross-namespace routing has been enable within the Gateway from using`allowedRoutes.from: All`. 

### 3. Cloudflare: DNS, then the setting that must be right.

Two things happen at Cloudflare:

```text
1. DNS: A record  boutique → <LoadBalancer IP from Step 1>
2. SSL/TLS mode: Flexible
```

The A record is the boring, important part: it's what makes `boutique.invincibledevops.tech` resolve to the LoadBalancer (propagation is usually 1–2 minutes). 


---

## Step 3 — Verify 

Prove the storefront is live before you start attacking it:

```bash
# Straight at the LoadBalancer, host header doing the routing
curl -H "Host: boutique.invincibledevops.tech" http://<LB_IP>/    # expect 200

# Through Cloudflare once DNS propagates
curl -I https://boutique.invincibledevops.tech
```

[image]

A 200 from the LoadBalancer proves the routing works. A 200 through Cloudflare proves the DNS, the proxy worked. Both green? 



Then the full tour — five classic attack classes hurled at `/search`:

```bash
./scripts/waf-test.sh https://boutique.invincibledevops.tech
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

5/5, with receipts in the proxy logs:

```bash
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway \
  | grep -i -E 'coraza|denied'
```

And if you want to go deeper than the script's five payloads, the project ships an OWASP ZAP passive scan — the same scanner security teams run against real estates:

```bash
./scripts/zap-scan.sh https://boutique.invincibledevops.tech
```

**The integrity check (worth doing once):** delete the `EnvoyExtensionPolicy` from Step 1 and re-run `waf-test.sh` — every payload sails through, because the app itself has no defense. Reapply the policy and they're blocked again. That before/after is the cleanest possible proof of where the protection actually lives: in the WAF, not in the app.

---

## What's next

The storefront is live, routed, DNS'd, and 5/5 against the attack set — Cloudflare in front, and a WAF that runs inside the proxy. But the front door is guarded while the hallway is still vanilla. In the next part we lock the inside the way we guarded the outside: **Cilium** — the eBPF dataplane that replaces kube-proxy, enforces NetworkPolicies, and encrypts every pod-to-pod packet with WireGuard. The WAF keeps the bad requests out; WireGuard makes the traffic they'd eavesdrop on unreadable anyway.
