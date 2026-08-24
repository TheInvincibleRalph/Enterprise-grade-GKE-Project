# [Part 11] Wrapping Up: What We Have Built, the Full Teardown, and Portfolio Value

## What we built

And just like that we are done building a production-grade platform on a free trial budget.

We have learnt a lot, experienced a lot, and built something fun and large. Now is the time to retire the project. To be honest, I don't feel like doing this. There is actually real beauty and joy in building something from scratch: I love seeing and reading the charts on Grafana and Datadog, I love going back to the code and pointing out what each piece does in the project, and I hope you love or would love doing the same. You can actually keep the cluster running for a while, but you can't keep it for too long, or you will quickly use up your credits.

Before we tear down the infra, let's go over the stack once again, phase by phase:

1. **Organization and cost controls.** A Google Cloud organization, IAM, a service account for Terraform, a dedicated project, and the billing discipline that made the whole thing possible: spot nodes, the `e2` machine family, project isolation, and a budget alert that stops the cluster before the credits run out.
2. **The cluster.** A regional GKE cluster with node pools spread across three availability zones, private and spot, provisioned entirely with Terraform. Six nodes: three for system workloads, three for applications.
3. **The storefront.** The Online Boutique, twelve microservices, behind an Envoy Gateway managed with the Gateway API. Cloudflare provides DNS and HTTPS on a real domain, so the platform was reachable from the public internet from the first phase.
4. **The WAF.** A Coraza Web Application Firewall with the OWASP Core Rule Set, attached cluster-wide to the gateway. SQL injection payloads and other OWASP Top 10 attacks answered 403 through the public hostname, verified by an automated test script.
5. **The network.** Cilium as the CNI, eBPF instead of kube-proxy, WireGuard encrypting pod-to-pod traffic, and Hubble observing the flows.
6. **The database.** CloudNativePG running PostgreSQL with three replicas spread across the zones, a leader with automatic promotion, proven under load with pgbench.
7. **The failover.** The leader killed, the replica promoted, the service restored, measured before and after. The one-off `kubectl delete pod` became a repeatable experiment.
8. **The observability.** Prometheus and Grafana dashboards for the database and the WAF, Datadog with agent and cluster agent, APM and logs, so the platform was not just running but measured.
9. **The chaos.** Chaos Mesh turning failure injection into declarative experiments: pod kills, CPU stress, with a steady-state hypothesis before every injection and the dashboards as the evidence layer.
10. **The AI.** An Ollama inference server with a persistent model disk, a Redis queue, a worker, and KEDA scaling the model to zero when idle and waking it when a job arrives. The same queue pattern that runs OpenAI Batch and Anthropic Message Batches, deployed on our own cluster.

The four pillars of the project and how they are materialized:

- security, the WAF and the encrypted network
- reliability, the HA database and the chaos experiments
- observability, the dashboards and the agent
- cost-awareness, the spot nodes, the scale-to-zero, and the budget kill switch


## The cleanup: shutting it all down

There are two layers to the teardown, and the choice between them is yours: either wait for the kill switch, and most of the credits are gone by the time it fires; or tear down by hand now, and keep the remaining budget for other projects. You choose. I'd prefer the latter for you.

### The automated kill switch

The kill switch is the Cloud Function we deployed earlier, triggered by a Pub/Sub budget alert. The budget publishes at 95% of the credits, and the function stops every running instance in the cluster zones.

### The ordered teardown

For a clean rebuild or a permanent close, the teardown runs in order, from the cluster up to the organization:

```bash
# 1. Destroy the infrastructure (node pools + cluster + networking, ~10 min).
#    Runs as terraform-sa via impersonation, no key file involved:
cd infra/terraform
terraform destroy -var-file=terraform.tfvars

# 2. Verify nothing is left running (all three should be empty):
gcloud compute instances list
gcloud compute addresses list
gcloud compute disks list

# 3. Delete the state bucket (holds terraform state and backups):
gcloud storage rm -r gs://devops-portfolio-tfstate

# 4. Local cleanup, done once, irreversible:
rm -rf .terraform
kubectl config delete-context gke_devops-portfolio-prod_us-central1_devops-portfolio
kubectl config delete-cluster gke_devops-portfolio-prod_us-central1_devops-portfolio

# 5. Delete the project, only if closing for good (30-day recovery window):
gcloud projects delete devops-portfolio-prod

# 6. Delete the folder, which must be empty first (also 30 days):
FOLDER_ID=$(gcloud resource-manager folders list \
  --organization=$(gcloud organizations list --format='value(ID)') \
  --filter='displayName="Infrastructure Engineering"' \
  --format='value(ID)')
gcloud resource-manager folders delete "$FOLDER_ID"
```

**Cloudflare (console):** DNS, remove the `boutique` A record created for the project. If the domain is reused elsewhere, reset the SSL mode from Flexible back to Full (strict).

Steps 1-4 remove the infrastructure and the state but leave the folder, the organization, and the identity layer intact: a fresh rebuild needs only a new project, a service account, and a state bucket. Steps 5-6 close the project for good, and both carry a 30-day recovery window. The organization itself cannot be deleted with gcloud; it lives on the Cloud Identity account, and closing it completely means cancelling the account from the admin console.

The order matters. The cluster is destroyed before the project, the project before the folder, and the folder only when it is empty. Skipping the order leaves orphaned resources, which is exactly what the kill switch exists to prevent, anyways. 

I speant $165 in total credit building the project twice and keeping it up for over 3 weeks in order to write and demo for the project series. Your spending should be less.

## After the teardown

The cluster is gone, the records are removed, the folder is closed. What remains is what you have learnt and the experience of building an enterprise-grade system from the ground up. So feel free to add the experience to your portfolio, something like:

"A production-shaped cloud platform on GKE: twelve microservices behind a WAF, a self-healing PostgreSQL cluster, chaos-validated reliability, and a scale-to-zero AI inference service, all provisioned as code and all under a $300 budget."

Or anything you can do to showcase your new knowledge and experience.

Finally, be on the lookout for more practical posts from me on DevOps and Cloud-Native technologies, and don't forget to clap and share.
