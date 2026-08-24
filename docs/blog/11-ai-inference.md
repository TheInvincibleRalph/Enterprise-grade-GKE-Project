# [Part 10] Deploying an Ollama Inference Server on GKE with KEDA

Event-Driven Autoscaling, Redis Queue, and an Async Inference API

An API inference server exposes a model over HTTP to receive prompts and return text. On its own, an AI model is just a static file of weights; Ollama is the server that actually loads it into memory and runs the inference. In production, this API is typically consumed by code, like backends or data pipelines. Because inference takes time, they don't wait for a response. They submit a prompt, get a task ID, and fetch the result when it's ready. This asynchronous pattern is the exact same contract used by OpenAI and Anthropic for their batch APIs.

Since our free trial cluster doesn't have GPUs, we are running inference on CPU using a small, quantized model (llama3.2:3b) served by Ollama. It processes one prompt at a time, and each takes a few seconds. The problem is idle cost: keeping 2 GB of weights loaded in memory doing nothing is the most expensive part of a node billed by the hour.

To solve this, we need an architecture that only exists when there is active work:

- The API accepts a prompt, returns a task ID immediately, and drops the connection.
- Redis holds the incoming prompts in a queue.
- A worker pulls jobs from Redis and calls the Ollama server to process them.
- KEDA (Kubernetes Event-driven Autoscaling) monitors the Redis queue to decide how many model replicas should be running.

KEDA is the critical component here. The built-in Kubernetes Horizontal Pod Autoscaler (HPA) scales based on CPU and memory, and it will never scale below one replica. KEDA, however, scales based on the actual workload (the queue depth) and can scale to zero. When the queue is empty, the model pod is terminated, and the idle cost drops to zero. This scale-to-zero mechanism is exactly how serverless, pay-per-inference platforms operate.

## Step 1: Deploy Ollama with a persistent model disk

We will be deploying a Deployment named ollama in its own namespace. The manifests expect the namespace to exist, so we create it first, then the disk, followed by the deployment:

[Enterprise-grade-GKE-Project/kubernetes/ai at master ·…](https://github.com/TheInvincibleRalph/Enterprise-grade-GKE-Project/tree/master/kubernetes/ai)

Contribute to TheInvincibleRalph/Enterprise-grade-GKE-Project development by creating an account on GitHub.github.com

```bash
kubectl create namespace ai-inference
kubectl apply -f kubernetes/ai/models-pvc.yaml
kubectl apply -f kubernetes/ai/ollama-deployment.yaml
```

The deployment mounts the claim ollama-models, a 10 Gi disk on standard-rwo, at the model directory. The disk is what makes scale-to-zero workable. A pod can be deleted at any moment, and a scale-to-zero cluster deletes pods constantly. If the model lived in the pod, every wake-up would re-download 2 GB before the first answer. On the disk, the cold start is a load from disk, not a download, so the model outlives every pod that serves it.

*For predictable scheduling, pause the boutique load generator while the AI phase runs, as the README documents: the app nodes are memory-constrained, and the model pod needs headroom on a node in the disk's zone.*

Pull the model onto the disk now, before KEDA exists. Once KEDA is live, an empty queue drops the pod to zero after 60 seconds, and with no pod there is nothing to exec into:

```bash
kubectl exec -n ai-inference deploy/ollama -- ollama pull llama3.2:3b
```

Let's test that our model is active by asking it something.

```bash
kubectl port-forward -n ai-inference svc/ollama 11434:11434

# then in a second terminal:
curl http://localhost:11434/api/generate \
  -d '{"model": "llama3.2:3b", "prompt": "Say hello in five words.", "stream": false}'
```

Both should work now, but after Step 3 the exec path will stop being reliable: KEDA may scale the deployment to zero, and there is no pod to exec into. After now, we will be using the Service name, ollama, in anything that needs to talk to the model.

*One thing worth knowing for a rebuild: the pull above must happen before KEDA exists. If KEDA is already live and the disk is empty, the deployment sits at zero replicas and there is no pod to exec into. Wake the model first by pushing one job through the API from Step 2, or by temporarily setting the ScaledObject's minReplicaCount to 1, then pull.*

## Step 2: The queue and the API

[Enterprise-grade-GKE-Project/kubernetes/ai/redis-inference-api.yaml at master ·…](https://github.com/TheInvincibleRalph/Enterprise-grade-GKE-Project/blob/master/kubernetes/ai/redis-inference-api.yaml)

Contribute to TheInvincibleRalph/Enterprise-grade-GKE-Project development by creating an account on GitHub.github.com

```bash
kubectl apply -f kubernetes/ai/redis-inference-api.yaml
```

This applies Redis, the API, and their Services.

Why a queue at all? Because the model is slow. An answer takes seconds on CPU, and an HTTP call that blocks for that long ties up the caller. So between the caller and the model sits a Redis list named inference_queue. The API does not talk to the model. It pushes the prompt into the list and answers immediately, with three endpoints:

- POST /infer: takes {"prompt": ...}, pushes a job onto the list, returns a task_id.
- GET /result/<id>: the answer once the worker wrote it, or processing while it is still being worked.
- GET /health: the current queue length.

The caller never waits on the model; it waits on the queue. And the queue is what KEDA watches. The API is the only entry point: nothing talks to Ollama directly except the worker from the next step.

*The API is honest about failure: if Redis is briefly unreachable, /result answers 503, which means "try again". A client that sees a 5xx retries; it does not crash.*

## Step 3: KEDA and the worker

[Enterprise-grade-GKE-Project/kubernetes/ai/queue-worker.yaml at master ·…](https://github.com/TheInvincibleRalph/Enterprise-grade-GKE-Project/blob/master/kubernetes/ai/queue-worker.yaml)

Contribute to TheInvincibleRalph/Enterprise-grade-GKE-Project development by creating an account on GitHub.github.com

```bash
kubectl apply -f kubernetes/ai/queue-worker.yaml

helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda --namespace keda --create-namespace
kubectl apply -f kubernetes/ai/scaledobject.yaml
```

The worker moves jobs from the queue to the model. Its loop: BRPOPLPUSH moves a job from inference_queue to inference_processing in one atomic step, it POSTs the prompt to http://ollama:11434/api/generate, stores the answer as result:<id>, and removes the job from the processing list.

KEDA scales on inference_processing, the list of jobs being worked, not on inference_queue. The raw queue looks empty the moment the worker pops a job, even though the model is still generating an answer. If KEDA watched the raw queue, it would scale the model down mid-generation. The job sits in the processing list from the moment the worker picks it up to the moment the answer is stored, so KEDA keeps the pod alive for exactly as long as there is real work.

*The worker is built to wait. While the job sits in the processing list, the worker retries the model with capped backoff: 20 attempts, the wait capped at 30 seconds, about 8 minutes in total. That window covers the worst cold start this cluster can produce. The job leaves the processing list only when it is answered, or when all 20 attempts fail and it goes back to the queue. It is never lost.*

Try to go through the reference-api and queue-worker and the manifests, and these things will get clearer.

Now to ScaledObject, which is a Kubernetes custom resource that comes with KEDA. It tells KEDA what to scale, how far, and on what signal.

Here, what to scale is the field scaleTargetRef and it points to the Deployment, ollama. minReplicaCount: 0 and maxReplicaCount: 1 are the bounds, zero at idle, one at most. The redis trigger watches inference_processing, and the tuning fields say how it behaves, cooldownPeriod: 60 (how long after the queue empties before scaling down) and pollingInterval: 10 (how often KEDA checks the queue).

*The manifest, as applied in this project:*

```yaml
# kubernetes/ai/scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ollama-scaler
  namespace: ai-inference
spec:
  scaleTargetRef:
    name: ollama
  minReplicaCount: 0
  maxReplicaCount: 1
  cooldownPeriod: 60
  pollingInterval: 10
  triggers:
    - type: redis
      metadata:
        address: redis.ai-inference.svc.cluster.local:6379
        listName: inference_processing
        listLength: "5"
        activationListLength: "0"
```

## Step 4: The scale-to-zero demo

*Start from a clean state so the demo behaves the same every run:*

```bash
./scripts/ai-demo-reset.sh
```

*The script stops the worker, empties the queue, the processing list, and any stored results, then starts the worker again. The worker restart matters: a worker mid-retry would requeue its held job after the flush, and the demo would not start clean. Then push the jobs. The first job pays the cold start, pod start plus model load, up to a few minutes on this hardware. The queue absorbs it, and the answer always comes.*

Push 20 jobs, from inside the API pod:

```bash
kubectl port-forward -n ai-inference svc/inference-api 8080:8080

# then in a second terminal:
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8080/infer -H 'Content-Type: application/json' \
    -d "{\"prompt\": \"What is Kubernetes? job $i\"}"
done
```

```bash
kubectl get deploy ollama -n ai-inference -w    # 0 -> 1 while a job is in flight, -> 0 after 60s quiet
```

The lifecycle: no jobs means no Ollama at all; the first job wakes it, and 60 seconds without a job shuts it down again. One worker works one job at a time, so one pod is enough, and the disk allows only one anyway.

The stack works now, but only inside the cluster. The next step gives it a hostname.

## Step 5: How a backend calls the inference server

In production, the consumer of an inference server is almost always code: another service, a pipeline, a backend. A product description generator, a ticket classifier, a nightly summarization job. The pattern is the same in every case: the caller submits a prompt and collects the answer when it is ready, and nobody watches it run.

The client side is short. This runs from the API pod, the same place a backend service on the cluster would call from:

```bash
kubectl exec -n ai-inference deploy/inference-api -- python -c "
import urllib.request, json, time

def submit(prompt):
    req = urllib.request.Request('http://inference-api:8080/infer',
        data=json.dumps({'prompt': prompt}).encode(),
        headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req).read())['task_id']
def wait_for(task_id):
    while True:
        res = json.loads(urllib.request.urlopen(
            'http://inference-api:8080/result/' + task_id).read())
        if 'response' in res:
            return res['response']
        print('job in flight, waiting...')
        time.sleep(2)
task = submit('Write a product description for a reusable water bottle.')
print(wait_for(task))
"
```

Run it once, and you see the lifecycle from the caller's side. The client submits, then prints job in flight, waiting... while the worker and the model start, then the answer appears. To the client, it is a request that takes longer than usual. To the cluster, it is a job that woke the model from zero, and 60 seconds after the queue empties, the model goes back to zero.

This is the code a pipeline runs in a loop over a dataset: submit all the prompts, collect the results, write them back to the database.

PS: The code job above might take a while to return if run almost immediatly after the scale-to-zero demo in Step 4.

*This is exactly what the reset script exists for: run ./scripts/ai-demo-reset.sh before this demo and the queue starts empty, so the answer comes back in the expected time.*

## What's next?

With that, the project is complete. Every promise from the overview is delivered: the storefront, the database, the observability, the chaos experiments, and the model. In the next post, I'll be sharing a kill switch to take down all the resources in the cluster in just one click and how the whole project is valuable to your portfolio.
