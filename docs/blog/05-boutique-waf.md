# Deploying a Microservices Application Behind a Real WAF

*Online Boutique, Gateway API routing, Cloudflare, and the 403s that prove it.*

Part 5 of the series. In Part 4 we built the edge: Envoy Gateway with the Coraza WAF running in-process, fronted by a single LoadBalancer IP — a front door with nobody inside. In this part we move the family in: **Google's Online Boutique**, a real microservices application, deployed behind that door, routed through the Gateway API, wrapped in Cloudflare — and then we prove the whole stack with requests that must never reach the app.

---

## Why Online Boutique?

Online Boutique is Google's official microservices-demo: a full e-commerce application built to show what real microservices look like — a product catalog, shopping cart, checkout, payments, shipping, recommendations, ads, currency conversion, and a frontend that renders a working storefront. Around eleven services plus a Redis cart, all speaking to each other over the network.

It is the perfect tenant for this cluster, for three reasons:

1. **It is genuinely microservice-shaped.** Dozens of pods, real inter-service calls, a stateful cache — the kind of topology that makes routing, DNS, and network policy *matter* instead of being academic.
2. **It is reference-grade and maintained by Google.** The manifests are published upstream in the official repo — no point re-vendoring twenty YAMLs into our repo when the source of truth lives with the people who built the demo.
3. **It gives the WAF a real target.** A working storefront with a search endpoint, query parameters, and forms is exactly the attack surface a production app has — which means the 403 proof at the end of this part is the real thing, not a synthetic demo.

---

## The following resources were deployed

1. **Namespace `boutique`** — the app's own corner of the cluster
2. **Online Boutique** — frontend + 11 microservices + redis-cart (upstream Google manifests)
3. **HTTPRoute `boutique-route`** — the app's contract with the edge: `boutique.invincibledevops.tech` → `frontend:80`
4. **Cloudflare** — A record + Flexible SSL: HTTPS to the world, plain HTTP to the origin

## Step 1 — Deploy the application

The cluster's edge is already live from Part 4 — the Gateway is accepted and the LoadBalancer has an IP. Deploying the storefront is one command:

```bash
BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh
```

Under the hood, the script does three jobs:

```bash
# 1. The app's namespace
kubectl apply -f kubernetes/boutique/namespace.yaml

# 2. The app itself — upstream manifests, straight from Google's repo
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml -n boutique

# 3. The route — your real host substituted into the shareable manifest
sed "s/boutique.example.dev/${BOUTIQUE_HOST}/" kubernetes/gateway/httproute.yaml | kubectl apply -f -
```

The script waits for the frontend to roll out, then shows you the lay of the land:

```bash
kubectl rollout status deployment/frontend -n boutique --timeout=5m
kubectl get pods,svc -n boutique
kubectl get httproute -n boutique
```

[image]

You should see a grid of Running pods — `frontend`, `cartservice`, `productcatalogservice`, `checkoutservice`, and friends — plus `redis-cart`, and the HTTPRoute reporting **Accepted=True**. Accepted means the Gateway API agreed with our route: the edge at `envoy-gateway-system` is willing to route this app's hostname.

---

## To understand what the config achieves, I will highlight important decisions or 'settings' that shaped this deployment.

### 1. One command, three responsibilities.

`deploy-boutique.sh` is deliberately three things in one: the namespace, the application, and the route. A real shop wouldn't deploy an app and forget its door; the script encodes that habit. The HTTPRoute is applied with a `sed` substitution of the host — the manifest in the repo keeps a placeholder (`boutique.example.dev`), so it stays shareable and honest, while the live cluster learns your real domain only at apply time.

### 2. The HTTPRoute is the app's contract with the edge.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: boutique-route
  namespace: boutique
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: envoy-gateway-system
  hostnames:
    - boutique.invincibledevops.tech
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
```

Two things worth noticing. First, **the route lives in a different namespace than the gateway** — `boutique` vs `envoy-gateway-system` — cross-namespace routing that needed zero extra config, because Part 4's Gateway was built with `allowedRoutes.from: All`. Second, **nothing on the edge changed to admit this app.** The door was designed to accept any route; the app just declared itself. That's the Gateway API's whole philosophy: the edge is shared infrastructure, and applications own their own routing rules.

### 3. Cloudflare: DNS, then the setting that must be right.

Two things happen at Cloudflare:

```text
1. DNS: A record  boutique → <LoadBalancer IP from Part 4>
2. SSL/TLS mode: Flexible
```

The A record is the boring, important part: it's what makes `boutique.invincibledevops.tech` resolve to the LoadBalancer (propagation is usually 1–2 minutes). The **Flexible** setting is the one that will bite you if you get it wrong: Flexible means HTTPS between the browser and Cloudflare, plain HTTP between Cloudflare and the origin — which is exactly what our Envoy Gateway serves on :80. Cloudflare's default advice is Full (strict), which assumes a TLS origin; with our HTTP-only origin, Full (strict) produces **521/502 errors at the edge**. If your storefront shows error pages through Cloudflare but works when you curl the LoadBalancer IP directly, this setting is the first suspect.

Is plain HTTP to the origin a security problem? Not here — the WAF still inspects every request in plaintext, and the only thing crossing the public wire is TLS'd browser-to-Cloudflare traffic; everything inside the cluster is WireGuard-encrypted in a later part. Cloudflare owns TLS, and the cluster stays simple.

### 4. The storefront's real job: give the WAF somewhere to prove itself.

A WAF with no traffic is a theory; a storefront with a search endpoint is a target. The verification in the next section throws real attack classes at `/search` and the query string — the same shapes of payloads that hit production apps every day.

---

## Step 2 — Verify the happy path first

Prove the storefront is live before you start attacking it:

```bash
# Straight at the LoadBalancer, host header doing the routing
curl -H "Host: boutique.invincibledevops.tech" http://<LB_IP>/    # expect 200

# Through Cloudflare once DNS propagates
curl -I https://boutique.invincibledevops.tech
```

[image]

A 200 from the LoadBalancer proves the routing works. A 200 through Cloudflare proves the DNS, the proxy, and the Flexible SSL chain work. Both green? The stage is set.

## Step 3 — The 403s that prove it

The money shot — a SQL injection that would silently empty an unprotected database:

```bash
curl -H "Host: boutique.invincibledevops.tech" \
  "http://<LB_IP>/?id=1'+OR+'1'='1"     # expect 403
```

Same gateway, same route, same cluster as the 200 above — the only difference is the request content. The OWASP Core Rule Set fired in-process (the Coraza module from Part 4), and the request died at the door. It never touched a microservice.

Then the full tour — five classic attack classes hurled at `/search`:

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

**The integrity check (worth doing once):** delete the `EnvoyExtensionPolicy` from Part 4 and re-run `waf-test.sh` — every payload sails through, because the app itself has no defense. Reapply the policy and they're blocked again. That before/after is the cleanest possible proof of where the protection actually lives: in the WAF, not in the app.

---

## What's next

The storefront is live, routed, DNS'd, and 5/5 against the attack set — with Cloudflare in front and a WAF that runs inside the proxy. In the next part we lock the inside the way we guarded the outside: **Cilium** — the eBPF dataplane, NetworkPolicy enforcement, and transparent WireGuard encryption between every pod. The bad requests stay out; the good traffic becomes unreadable in transit.
