# Gateway API Inference Extension with NGINX Gateway Fabric

This lab shows how NGINX Gateway Fabric (NGF) becomes an **Inference Gateway** when it is combined with the
[Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/) (GAIE).

The first part of the lab deploys the inference stack. The rest of the lab compares a **plain Kubernetes Service** with an
**InferencePool** over the *same* model server pods, through the *same* Gateway. Each exercise shows a problem that
traditional load balancing cannot solve for LLM traffic.

| Part | You will learn |
|------|----------------|
| 1 | Deploy model servers, the InferencePool, the Endpoint Picker, a Gateway and an HTTPRoute |
| 2 | How NGF and the Endpoint Picker work together (look at the generated NGINX config) |
| 3 | Build a "traditional" round-robin baseline on the same Gateway |
| 4 | **Prefix-cache aware routing**: requests that share a prompt prefix stick to one pod |
| 5 | **Load aware routing**: an overloaded pod is avoided, and tail latency stays flat |
| 6 | Tune the Endpoint Picker **scorer chain** and see what each scorer contributes |
| 7 | Observe the Endpoint Picker with its Prometheus metrics |
| 8 | **Priority** with `InferenceObjective`, and the effect of `failureMode` |
| 9 | **Model rollout** (canary) with weighted InferencePool backends |
| 10 | Beyond this lab: prefill/decode disaggregation and KV-cache offload (llm-d) |

> [!NOTE]
> The model servers in this lab are the [llm-d vLLM simulator](https://github.com/llm-d/llm-d-inference-sim).
> It does not use GPUs and does not run a real model, but it speaks the vLLM OpenAI-compatible API and exposes the same
> Prometheus metrics as vLLM (queue depth, KV-cache usage, LoRA adapters). The Endpoint Picker cannot tell the
> difference, so all routing behaviour in this lab is real. Only the token throughput is simulated.

---

## Concepts

### Why LLM traffic needs a different load balancer

A normal load balancer (round robin, least connections, random) assumes that every request costs about the same.
For LLM inference this is wrong:

| Signal | Why it matters | Visible to a normal load balancer? |
|--------|----------------|------------------------------------|
| **Prefix cache** | vLLM caches the KV-cache of prompts it has already processed. If two requests share a long prefix (system prompt, RAG context, few-shot examples), the second one is much faster *on the same pod*. On a different pod, the prefix has to be computed again. | No |
| **KV-cache utilization** | GPU memory holds the KV-cache of all running requests. A pod near 100% must queue or evict work. | No |
| **Queue depth** | One request that generates 2000 tokens keeps a slot busy for a long time. "1 connection" does not mean "lightly loaded". | No |
| **Model / LoRA adapter** | The request body says which model or adapter is needed (`"model": "food-review-1"`). | No (it is in the JSON body, not in the headers) |
| **Prefill vs. decode** | Processing the prompt (prefill) is compute bound. Generating tokens (decode) is memory-bandwidth bound. | No |

None of this is expressed in HTTP headers or the URL. The information is in the **request body** and in the **model
server metrics**.

### The pieces

```
                         +-----------------------------+
                         |  Endpoint Picker (EPP)       |
                         |  - scrapes /metrics of pods  |
                         |  - scores every pod          |
                         |  - returns the best pod      |
                         +--------------^--------------+
                                        | 2. "which pod?"  (gRPC ext-proc, port 9002)
                                        | 3. "pod 192.168.x.y:8000"
  +--------+  1. POST /v1/completions  +-+-----------------------+   4. proxy request   +-----------------------+
  | client | ------------------------> | NGINX Gateway Fabric    | -------------------> | model server pod      |
  +--------+                           | (data plane)            |                      | (selected by the EPP) |
                                       +-------------------------+                      +-----------------------+
```

| Resource | API | Purpose |
|----------|-----|---------|
| `Gateway` | `gateway.networking.k8s.io/v1` | The listener (port 80). NGF deploys an NGINX data plane pod for it. |
| `HTTPRoute` | `gateway.networking.k8s.io/v1` | Matches requests and sends them to a `backendRef`. With GAIE the backend can be an `InferencePool` instead of a `Service`. |
| `InferencePool` | `inference.networking.k8s.io/v1` | A group of model server pods (selected by label) plus a reference to the Endpoint Picker that chooses between them. Think of it as "a Service with a brain". |
| Endpoint Picker (EPP) | Deployment + Service | Scores the pods in the pool using a chain of plugins (scorers) and tells the gateway which pod to use. |
| `InferenceObjective` | `inference.networking.x-k8s.io/v1alpha2` | Gives requests a priority, so the EPP knows what to serve first and what to drop under load. |

NGF still does all the proxying: TLS, routing, headers, rate limiting, WAF, and so on. It only asks the EPP **which
pod** should get the request.

---

## Part 1 - Deploy the inference stack

### 1.1 Lab directory

```code
cd ~/lab10-test
```

### 1.2 Deploy the model servers

Three replicas of the vLLM simulator. They serve the base model `Qwen/Qwen3-32B` and a LoRA adapter called
`food-review-1`.

```code
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/refs/tags/v1.5.0/config/manifests/vllm/sim-deployment.yaml
```

```code
kubectl get pods -l app=vllm-qwen3-32b -o wide
```

Output should be similar to

```code
NAME                              READY   STATUS    RESTARTS   AGE   IP                NODE
vllm-qwen3-32b-5b5f77f8d9-6xg5h   1/1     Running   0          20s   192.168.36.120    k8s-node1
vllm-qwen3-32b-5b5f77f8d9-8dvnq   1/1     Running   0          20s   192.168.36.126    k8s-node1
vllm-qwen3-32b-5b5f77f8d9-d6zk7   1/1     Running   0          20s   192.168.169.186   k8s-node2
```

### 1.3 Deploy the InferencePool and the Endpoint Picker

This lab uses a values file to make the Endpoint Picker configuration visible. Look at it first:

```code
cat values/epp-default.yaml
```

```yaml
inferencePool:
  modelServers:
    matchLabels:
      app: vllm-qwen3-32b              # <- the InferencePool selects pods with this label
inferenceExtension:
  resources:
    requests: {cpu: 100m, memory: 512Mi}
    limits: {memory: 2Gi}
  pluginsConfigFile: custom-plugins.yaml
  pluginsCustomConfig:
    custom-plugins.yaml: |
      apiVersion: inference.networking.x-k8s.io/v1alpha1
      kind: EndpointPickerConfig
      plugins:
      - type: queue-scorer                  # prefers pods with short queues
      - type: kv-cache-utilization-scorer   # prefers pods with free KV-cache
      - type: prefix-cache-scorer           # prefers pods that already have the prompt prefix cached
      - type: metrics-data-source           # scrapes /metrics from every pod (required)
      - type: core-metrics-extractor        # turns vLLM metrics into queue/KV values (required)
      schedulingProfiles:
      - name: default
        plugins:
        - {pluginRef: queue-scorer, weight: 2}
        - {pluginRef: kv-cache-utilization-scorer, weight: 2}
        - {pluginRef: prefix-cache-scorer, weight: 3}
```

For every request, each scorer gives each pod a score between 0 and 1. The EPP multiplies the scores by their
weights, adds them up, and picks the pod with the highest total. This is the same configuration as the chart
default. We only write it out so we can change it in Part 6.

> [!IMPORTANT]
> If you write your own plugin list, always keep `metrics-data-source` and `core-metrics-extractor`.
> Without them the EPP does not collect any metrics from the pods, and the queue and KV-cache scorers have no data.

Install the chart:

```code
helm install vllm-qwen3-32b \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.5.0 \
  -f values/epp-default.yaml
```

```code
kubectl get pods
kubectl get inferencepool
```

Output should be similar to

```code
NAME                                  READY   STATUS    RESTARTS   AGE
vllm-qwen3-32b-5b5f77f8d9-6xg5h       1/1     Running   0          2m
vllm-qwen3-32b-5b5f77f8d9-8dvnq       1/1     Running   0          2m
vllm-qwen3-32b-5b5f77f8d9-d6zk7       1/1     Running   0          2m
vllm-qwen3-32b-epp-775b94dbd6-hk58d   1/1     Running   0          20s

NAME             AGE
vllm-qwen3-32b   20s
```

Look at the InferencePool:

```code
kubectl get inferencepool vllm-qwen3-32b -o yaml | sed -n '/^spec/,/^status/p'
```

```yaml
spec:
  appProtocol: http
  endpointPickerRef:
    failureMode: FailOpen          # what to do if the EPP fails or refuses a request (see Part 8)
    kind: Service
    name: vllm-qwen3-32b-epp       # the Endpoint Picker service
    port:
      number: 9002
  selector:
    matchLabels:
      app: vllm-qwen3-32b          # the model server pods
  targetPorts:
  - number: 8000
```

### 1.4 Create the Gateway

```code
kubectl apply -f 0.gateway.yaml
```

This deploys the NGF data plane pod `inference-gateway-nginx-...`. It has 4 containers. One of them,
`endpoint-picker-shim`, is the NGF component that talks to the EPP.

```code
kubectl get gateway inference-gateway
kubectl get pods -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

Output should be similar to

```code
NAME                CLASS   ADDRESS          PROGRAMMED   AGE
inference-gateway   nginx   10.110.243.190   True         30s

NAME                                      READY   STATUS    RESTARTS   AGE
inference-gateway-nginx-c55c56fdf-r4qs5   4/4     Running   0          30s
```

### 1.5 Create the HTTPRoute

```code
cat 1.httproute.yaml
```

The only difference from a "normal" HTTPRoute is the `backendRef`: it points to an `InferencePool` instead of a `Service`.

```yaml
  rules:
  - backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-qwen3-32b
```

```code
kubectl apply -f 1.httproute.yaml
kubectl get inferencepool vllm-qwen3-32b -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

Output should be similar to

```code
Accepted=True The InferencePool is accepted by the Gateway.
ResolvedRefs=True The InferencePool references a valid ExtensionRef.
```

### 1.6 Get the gateway address

The Gateway is exposed as a NodePort. Use the IP of the node that runs the NGINX data plane pod:

```code
export NGF_IP=$(kubectl get pod -l gateway.networking.k8s.io/gateway-name=inference-gateway -o jsonpath='{.items[0].status.hostIP}')
export HTTP_PORT=$(kubectl get svc inference-gateway-nginx -o jsonpath='{.spec.ports[0].nodePort}')
echo -e "NGF address: $NGF_IP\nHTTP port  : $HTTP_PORT"
```

### 1.7 Send a first prompt

```code
curl -i $NGF_IP:$HTTP_PORT/v1/completions -H 'Content-Type: application/json' -d '{
"model": "food-review-1",
"prompt": "Write as if you were a critic: San Francisco",
"max_tokens": 100,
"temperature": 0
}'
```

Output should be similar to

```code
HTTP/1.1 200 OK
Server: nginx
Content-Type: application/json
X-Inference-Pod: vllm-qwen3-32b-5b5f77f8d9-6xg5h
X-Inference-Port: 8000

{"id":"cmpl-...","model":"food-review-1","usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60},"object":"text_completion","choices":[...]}
```

The model server adds the `X-Inference-Pod` response header. In this lab we use it to see **which pod the request
was sent to**.

`food-review-1` is a **LoRA adapter**, a small fine-tuned add-on that runs on the base model. The gateway reads the
`model` field from the JSON body. You can also ask for the base model:

```code
curl -s $NGF_IP:$HTTP_PORT/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-32B","prompt":"hello","max_tokens":5}' | jq .model
```

---

## Part 2 - How NGF talks to the Endpoint Picker

Look at the NGINX configuration that NGF generated for the InferencePool route:

```code
NGINX_POD=$(kubectl get pod -l gateway.networking.k8s.io/gateway-name=inference-gateway -o jsonpath='{.items[0].metadata.name}')
kubectl exec $NGINX_POD -c nginx -- nginx -T 2>/dev/null | sed -n '/^server {/,/^}/p' | grep -vE '^\s*$'
```

The important parts (shortened):

```nginx
    location / {
        js_var $inference_workload_endpoint;
        set $epp_internal_path /_ngf-internal-proxy-pass-rule0-route0-backend0-inference;
        set $epp_host vllm-qwen3-32b-epp.default;      # the Endpoint Picker service
        set $epp_port 9002;
        js_content epp.getEndpoint;                     # (1) ask the EPP which pod to use
    }

    location /_ngf-internal-proxy-pass-rule0-route0-backend0-inference {
        internal;
        proxy_pass http://$inference_backend_default_vllm_qwen3_32b_pool_svc_8000$request_uri;   # (2) proxy to that pod
    }
```

and outside the `server` block:

```nginx
map $inference_workload_endpoint $inference_backend_default_vllm_qwen3_32b_pool_svc_8000 {
    ""   default_vllm-qwen3-32b-pool-svc_8000;     # (3) no answer from the EPP -> use the normal upstream
    ~.+  $inference_workload_endpoint;              #     answer from the EPP     -> use the pod it chose
}

upstream default_vllm-qwen3-32b-pool-svc_8000 {
    random two least_conn;                          #     the fallback is ordinary NGINX load balancing
    ...
}
```

1. For every request, NGINX (njs module `epp.getEndpoint`) calls the `endpoint-picker-shim` container. The shim
   forwards the request headers and body to the EPP over gRPC.
2. The EPP answers with a pod address, for example `192.168.36.120:8000`, and NGINX proxies the request there.
3. If the EPP gives no address, NGINX uses a normal upstream that contains all pods of the pool. This is what
   `failureMode: FailOpen` means. More on this in Part 8.

You can see the decisions in the shim log:

```code
kubectl logs $NGINX_POD -c endpoint-picker-shim --tail=4
```

```code
{"level":"info","logger":"endpoint-picker-shim","msg":"Getting inference workload endpoint from EndpointPicker","endpointPicker":"vllm-qwen3-32b-epp.default:9002"}
{"level":"info","logger":"endpoint-picker-shim","msg":"Found endpoint","endpoint":"192.168.36.120:8000"}
```

> [!NOTE]
> The log also says `No BackendTLSPolicy configured for EndpointPicker; skipping TLS certificate verification`.
> NGF connects to the EPP over TLS but does not verify its certificate unless a `BackendTLSPolicy` targets the EPP
> Service. For production, see the
> [NGF documentation](https://docs.nginx.com/nginx-gateway-fabric/how-to/gateway-api-inference-extension/).

---

## Part 3 - Build a "traditional" baseline

To compare, we add a second route on the **same Gateway** that sends traffic to the **same pods** through a plain
Kubernetes Service. NGINX then load balances on its own, with no Endpoint Picker.

```
/v1/...     -> HTTPRoute llm-route          -> InferencePool vllm-qwen3-32b  (EPP decides)
/rr/v1/...  -> HTTPRoute llm-route-baseline -> Service vllm-qwen3-32b-rr     (NGINX random two least_conn)
```

```code
cat 2.service-baseline.yaml 3.httproute-baseline.yaml
kubectl apply -f 2.service-baseline.yaml -f 3.httproute-baseline.yaml
```

The baseline route uses three Gateway API / NGF features you know from earlier labs:
- `PathPrefix: /rr` match
- `URLRewrite` with `ReplacePrefixMatch: /`, so the model server still receives `/v1/completions`
- a `SnippetsFilter` that adds an `X-Upstream-Addr` response header

Check that NGF really applied the configuration. The route status only says that the route is valid. It does
not prove that NGINX accepted the generated config:

```code
kubectl get httproute llm-route-baseline -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n nginx-gateway logs deploy/ngf-nginx-gateway-fabric --since=1m | grep -E "successfully updated|Failed to update" | tail -2
```

Output should be similar to

```code
Accepted=True
ResolvedRefs=True
{"level":"info", ... "msg":"NGINX configuration was successfully updated"}
```

Send a request through the baseline:

```code
curl -s -D - -o /dev/null $NGF_IP:$HTTP_PORT/rr/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"food-review-1","prompt":"hello","max_tokens":5}' | grep -iE "^HTTP|x-inference-pod|x-upstream-addr"
```

```code
HTTP/1.1 200 OK
X-Inference-Pod: vllm-qwen3-32b-5b5f77f8d9-8dvnq
X-Upstream-Addr: 192.168.36.126:8000
```

> [!WARNING]
> **Don't** build the baseline by matching a header (for example `x-lb-mode: round-robin`) on the **same path**
> as the InferencePool rule. With NGF 2.8.0, mixing a Service backend and an InferencePool backend for the same path
> makes NGINX reject the config (`unknown "inference_backend_..." variable`). NGF then rolls back. The route still
> shows `Accepted=True`, but the traffic doesn't change. Always check the NGF controller log as shown above.
> If the `/rr` route later returns `502`, delete and re-apply `3.httproute-baseline.yaml`.

### The test scripts

Two helper scripts are in the lab directory:

```code
./tally.sh <path> <mode> [N] [parallel]
```

`tally.sh` sends `N` requests and counts which pod served each one (from the `X-Inference-Pod` header).
- `path`: `""` for the InferencePool route, `/rr` for the baseline route
- `mode`: `shared` means every prompt starts with the same 400-character "system prompt" and ends with a different
  question. `distinct` means every prompt is random.

```code
./latency.sh <path> [N]
```

`latency.sh` sends `N` requests one after the other and prints average, median and maximum latency.

---

## Part 4 - Prefix-cache aware routing

**Scenario:** Your application sends every request with the same long system prompt (a chatbot persona, a RAG
template, a runbook). vLLM can reuse the KV-cache for that prefix, but only on the pod that has already
processed it.

### 4.1 Shared prefix through the baseline

```code
./tally.sh /rr shared 12
```

```code
      3 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      6 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      3 vllm-qwen3-32b-5b5f77f8d9-d6zk7
```

The requests are spread over all pods. Each pod has to compute the same 400-character prefix again. With
real GPUs and a 4k-token prefix, that is the difference between tens of milliseconds and seconds of time-to-first-token.

### 4.2 Shared prefix through the InferencePool

```code
./tally.sh "" shared 12
```

```code
     12 vllm-qwen3-32b-5b5f77f8d9-8dvnq
```

**All 12 requests go to the same pod.** The `prefix-cache-scorer` remembers which pod received which prompt
prefix, and gives that pod the highest score.

Do the same with 8 concurrent clients:

```code
./tally.sh /rr shared 24 8
./tally.sh "" shared 24 8
```

```code
# baseline                                      # InferencePool
      9 vllm-qwen3-32b-5b5f77f8d9-6xg5h               24 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      6 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      9 vllm-qwen3-32b-5b5f77f8d9-d6zk7
```

### 4.3 Unrelated prompts through the InferencePool

```code
./tally.sh "" distinct 12
```

```code
      3 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      5 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      4 vllm-qwen3-32b-5b5f77f8d9-d6zk7
```

With no shared prefix there is nothing to reuse. The queue and KV-cache scorers spread the load across pods.
So the EPP does not just send everything to one pod. It keeps requests together only when that saves work.

### 4.4 Short prompts

```code
for i in $(seq 1 12); do
  curl -s -D - -o /dev/null $NGF_IP:$HTTP_PORT/v1/completions -H 'Content-Type: application/json' \
    -d '{"model":"food-review-1","prompt":"hello","max_tokens":5}' | grep -i x-inference-pod
done | sort | uniq -c
```

The requests are spread across pods even though the prompt is identical. The EPP hashes prompts in **blocks of
64 characters** (about 16 tokens, which is one vLLM KV-cache block). A prompt shorter than one block has no
cacheable prefix, so there is nothing to keep together.

> [!NOTE]
> **How does the EPP know what is cached?** In this configuration it does not ask the model server. It keeps its own
> *approximate* index: "I sent prefix X to pod A, so pod A probably has it cached". That is why prefix routing works
> even with the simulator. The llm-d project also has a *precise* mode, where vLLM publishes KV-cache events to the
> scheduler.

---

## Part 5 - Load aware routing

**Scenario:** One of your GPU pods is overloaded: a long-running batch job, a noisy tenant, a degraded GPU. It still
passes its readiness probe. A Kubernetes Service keeps sending it a fair share of traffic.

### 5.1 Add an overloaded pod

```code
cat 4.sim-hot-pod.yaml
kubectl apply -f 4.sim-hot-pod.yaml
kubectl rollout status deploy/vllm-qwen3-32b-hot
```

The new pod has the label `app: vllm-qwen3-32b`, so it joins **both** the InferencePool and the baseline Service. It:
- reports 15 running requests, 20 waiting requests and 95% KV-cache usage on its `/metrics` endpoint
- answers every request after 3 seconds

Look at the metrics the EPP sees. Compare the hot pod with a normal pod:

```code
HOT_POD=$(kubectl get pod -l role=hot -o jsonpath='{.items[0].metadata.name}')
NORMAL_POD=$(kubectl get pod -l app=vllm-qwen3-32b,role!=hot -o jsonpath='{.items[0].metadata.name}')
for p in $HOT_POD $NORMAL_POD; do
  echo "== $p"
  kubectl port-forward pod/$p 18000:8000 >/dev/null 2>&1 & PF=$!; sleep 2
  curl -s localhost:18000/metrics | grep -E "^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc)"
  kill $PF; wait $PF 2>/dev/null
done
```

```code
== vllm-qwen3-32b-hot-86f6df589-jczrk
vllm:kv_cache_usage_perc{model_name="Qwen/Qwen3-32B"} 0.95
vllm:num_requests_running{model_name="Qwen/Qwen3-32B"} 15
vllm:num_requests_waiting{model_name="Qwen/Qwen3-32B"} 20
== vllm-qwen3-32b-5b5f77f8d9-6xg5h
vllm:kv_cache_usage_perc{model_name="Qwen/Qwen3-32B"} 0
vllm:num_requests_running{model_name="Qwen/Qwen3-32B"} 0
vllm:num_requests_waiting{model_name="Qwen/Qwen3-32B"} 0
```

Wait about 10 seconds so the EPP scrapes the new pod.

### 5.2 Compare routing

```code
./tally.sh /rr distinct 16
./tally.sh "" distinct 16
```

```code
# baseline                                        # InferencePool
      3 vllm-qwen3-32b-5b5f77f8d9-6xg5h                  8 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      1 vllm-qwen3-32b-5b5f77f8d9-8dvnq                  4 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      7 vllm-qwen3-32b-5b5f77f8d9-d6zk7                  4 vllm-qwen3-32b-5b5f77f8d9-d6zk7
      5 vllm-qwen3-32b-hot-86f6df589-jczrk
```

The baseline sends about a quarter of the traffic to the overloaded pod. **The InferencePool sends none.**

Now try it with 8 concurrent clients:

```code
./tally.sh /rr distinct 24 8
```

The baseline now sends fewer requests (often 1 or 2) to the hot pod. NGINX's `random two least_conn` algorithm
counts **open connections**. Requests to the hot pod take 3 s, so its connections stay open and NGINX picks it less often.
This is a useful *side effect*, but it only works when the client is already waiting on the slow pod. NGINX still
cannot see the 20 queued requests or the 95% KV-cache usage, and with low traffic (one request at a time) it has no
signal at all. The EPP reads the real load from the model server metrics, so it avoids the pod in both cases.

### 5.3 Compare latency

```code
./latency.sh /rr 16
./latency.sh ""  16
```

```code
requests=16  avg=0.939s  p50=0.001s  max=3.003s      # baseline
requests=16  avg=0.016s  p50=0.016s  max=0.017s      # InferencePool
```

The median (p50) of the baseline looks fine, because most requests go to healthy pods. The **average and the tail**
are dominated by the overloaded pod. For users this is the important number: one slow pod makes the whole service
look slow. Inference-aware routing keeps the tail flat.

---

## Part 6 - Tune the scorer chain

The routing behaviour comes from the scorers and their weights. Try two extreme configurations to see what each
scorer contributes. Keep the hot pod running.

```code
diff values/epp-default.yaml values/epp-prefix-only.yaml
diff values/epp-default.yaml values/epp-load-only.yaml
```

### 6.1 Prefix-cache scorer only

```code
helm upgrade vllm-qwen3-32b oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.5.0 -f values/epp-prefix-only.yaml
kubectl rollout restart deploy/vllm-qwen3-32b-epp
kubectl rollout status deploy/vllm-qwen3-32b-epp
sleep 10
```

> [!NOTE]
> The EPP reads its configuration only at startup, so restart it after every `helm upgrade` that changes the plugins.

```code
./tally.sh "" distinct 16
./tally.sh "" shared 12
```

```code
      2 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      7 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      5 vllm-qwen3-32b-5b5f77f8d9-d6zk7
      2 vllm-qwen3-32b-hot-86f6df589-jczrk          <- the overloaded pod gets traffic again

     12 vllm-qwen3-32b-5b5f77f8d9-8dvnq            <- prefix affinity still works
```

Without the load scorers, the EPP can't see that the hot pod is overloaded. Unrelated prompts are spread
randomly, including to the hot pod. A shared prefix that happened to land on the hot pod would also *stay* there.

### 6.2 Load scorers only

```code
helm upgrade vllm-qwen3-32b oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.5.0 -f values/epp-load-only.yaml
kubectl rollout restart deploy/vllm-qwen3-32b-epp
kubectl rollout status deploy/vllm-qwen3-32b-epp
sleep 10
```

```code
./tally.sh "" distinct 16
./tally.sh "" shared 12
```

```code
      5 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      6 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      5 vllm-qwen3-32b-5b5f77f8d9-d6zk7               <- hot pod avoided

      4 vllm-qwen3-32b-5b5f77f8d9-6xg5h
      3 vllm-qwen3-32b-5b5f77f8d9-8dvnq
      5 vllm-qwen3-32b-5b5f77f8d9-d6zk7               <- prefix affinity is gone
```

### 6.3 Summary

| Configuration | Avoids overloaded pod | Keeps shared prefixes together |
|---------------|:---------------------:|:------------------------------:|
| Kubernetes Service (baseline) | no | no |
| `prefix-cache-scorer` only | no | yes |
| `queue-scorer` + `kv-cache-utilization-scorer` only | yes | no |
| **default (2 / 2 / 3)** | **yes** | **yes** |

The default weights give prefix reuse a slightly higher weight (3) than each load signal (2). Cache affinity
wins while a pod is healthy, and the load scorers together (2 + 2) win when that pod becomes overloaded.

Restore the default configuration:

```code
helm upgrade vllm-qwen3-32b oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.5.0 -f values/epp-default.yaml
kubectl rollout restart deploy/vllm-qwen3-32b-epp
kubectl rollout status deploy/vllm-qwen3-32b-epp
```

---

## Part 7 - Observe the Endpoint Picker

The EPP exposes Prometheus metrics on port 9090. The endpoint requires authentication:
- without a token you get `401`
- with a token, but without the RBAC below, you get `500` (the EPP is not allowed to validate the token)

```code
cat 5.epp-metrics-rbac.yaml
kubectl apply -f 5.epp-metrics-rbac.yaml
```

This creates:
- a `system:auth-delegator` binding for the EPP service account, so the EPP can validate tokens
- a `metrics-reader` service account that is allowed to `GET /metrics`

Read the metrics:

```code
kubectl port-forward svc/vllm-qwen3-32b-epp 19090:9090 >/dev/null 2>&1 &
TOKEN=$(kubectl create token metrics-reader --duration=10m)
./tally.sh "" shared 6 >/dev/null; ./tally.sh "" distinct 6 >/dev/null
curl -s -H "Authorization: Bearer $TOKEN" localhost:19090/metrics | grep -E "^inference_pool_|^inference_extension_prefix_indexer_(size|hit_ratio_(sum|count))|^inference_objective_request_total|plugin_duration_seconds_count\{extension_point=\"Scorer\""
```

Output should be similar to

```code
inference_extension_plugin_duration_seconds_count{extension_point="Scorer",plugin_name="kv-cache-utilization-scorer",...} 12
inference_extension_plugin_duration_seconds_count{extension_point="Scorer",plugin_name="prefix-cache-scorer",...} 12
inference_extension_plugin_duration_seconds_count{extension_point="Scorer",plugin_name="queue-scorer",...} 12
inference_extension_prefix_indexer_hit_ratio_sum 5
inference_extension_prefix_indexer_hit_ratio_count 12
inference_extension_prefix_indexer_size 30
inference_objective_request_total{model_name="food-review-1",priority="0",target_model_name="food-review-1"} 12
inference_pool_average_kv_cache_utilization{name="vllm-qwen3-32b"} 0.2375
inference_pool_average_queue_size{name="vllm-qwen3-32b"} 5
inference_pool_per_pod_queue_size{model_server_pod="vllm-qwen3-32b-5b5f77f8d9-6xg5h-rank-0",name="vllm-qwen3-32b"} 0
inference_pool_per_pod_queue_size{model_server_pod="vllm-qwen3-32b-5b5f77f8d9-8dvnq-rank-0",name="vllm-qwen3-32b"} 0
inference_pool_per_pod_queue_size{model_server_pod="vllm-qwen3-32b-5b5f77f8d9-d6zk7-rank-0",name="vllm-qwen3-32b"} 0
inference_pool_per_pod_queue_size{model_server_pod="vllm-qwen3-32b-hot-86f6df589-jczrk-rank-0",name="vllm-qwen3-32b"} 20
inference_pool_ready_pods{name="vllm-qwen3-32b"} 4
```

| Metric | Meaning |
|--------|---------|
| `inference_pool_per_pod_queue_size` | The queue depth the EPP sees for each pod. The hot pod shows 20, which is why it is avoided. |
| `inference_pool_average_kv_cache_utilization` | Average KV-cache usage of the pool. A good signal for **autoscaling** model servers (better than CPU). |
| `inference_extension_prefix_indexer_*` | Size and hit ratio of the EPP's prefix index |
| `inference_extension_plugin_duration_seconds` | How often each scorer ran and how long it took |
| `inference_objective_request_total` | Requests per model and priority (see Part 8) |

```code
kill %1
```

---

## Part 8 - Priority and failure mode

**Scenario:** Interactive chat users (premium) and an offline batch job share the same GPUs. When the pool is
saturated, chat requests should be served and batch requests should be dropped.

### 8.1 Create InferenceObjectives

```code
cat 6.inferenceobjective.yaml
kubectl apply -f 6.inferenceobjective.yaml
kubectl get inferenceobjectives
```

```code
NAME      INFERENCE POOL   PRIORITY   AGE
batch     vllm-qwen3-32b   -10        2s
premium   vllm-qwen3-32b   10         2s
```

Clients choose an objective with the `x-gateway-inference-objective` header. Requests with **negative priority are
sheddable**: when the EPP decides the pool is saturated, it refuses them.

The hot pod from Part 5 is still running. Its 20 queued requests make the pool look saturated.

### 8.2 Send premium and batch requests

```code
for o in premium batch batch batch; do
  curl -s -o /dev/null -w "$o -> %{http_code} %header{x-inference-pod}\n" $NGF_IP:$HTTP_PORT/v1/completions \
    -H "x-gateway-inference-objective: $o" -H 'Content-Type: application/json' \
    -d '{"model":"food-review-1","prompt":"hi there","max_tokens":5}'
done
```

```code
premium -> 200 vllm-qwen3-32b-5b5f77f8d9-6xg5h
batch -> 200 vllm-qwen3-32b-hot-86f6df589-jczrk
batch -> 200 vllm-qwen3-32b-5b5f77f8d9-6xg5h
batch -> 200 vllm-qwen3-32b-5b5f77f8d9-d6zk7
```

All requests succeeded, and one batch request even went to the overloaded pod. Why? Look at the logs:

```code
kubectl logs deploy/vllm-qwen3-32b-epp --since=2m | grep -o '"error":"[^"]*"' | sort | uniq -c
kubectl logs $NGINX_POD -c nginx --since=2m | grep EndpointPicker
```

```code
      6 "error":"inference error: ResourceExhausted - system saturated, sheddable request dropped"

[error] ... js: could not get specific inference endpoint from EndpointPicker; status: 429; body: inference error: ResourceExhausted - system saturated, sheddable request dropped
```

The EPP **did** drop the 3 batch requests with HTTP 429. It logs two lines per dropped request. But the InferencePool has `failureMode: FailOpen`. When the EPP
returns no endpoint, NGINX uses the fallback upstream (`random two least_conn`, see Part 2), which knows nothing
about load.

### 8.3 FailClose

```code
kubectl patch inferencepool vllm-qwen3-32b --type=merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailClose"}}}'
sleep 5
for o in premium batch; do
  curl -s -o /dev/null -w "$o -> %{http_code} %header{x-inference-pod}\n" $NGF_IP:$HTTP_PORT/v1/completions \
    -H "x-gateway-inference-objective: $o" -H 'Content-Type: application/json' \
    -d '{"model":"food-review-1","prompt":"hi there","max_tokens":5}'
done
```

```code
premium -> 200 vllm-qwen3-32b-5b5f77f8d9-6xg5h
batch -> 500
```

Now the batch request is rejected and the premium request is still served.

| failureMode | EPP down or refusing | Good for |
|-------------|----------------------|----------|
| `FailOpen` (default) | NGINX falls back to normal load balancing across all pool pods | availability first. The EPP is never a single point of failure, but load shedding and priority are not enforced. |
| `FailClose` | Request fails | strict enforcement of the EPP's decisions. Run the EPP with more than one replica. |

> [!NOTE]
> With NGF 2.8.0 the client receives `500` even though the EPP returned `429`. Clients should treat both as "retry later".

Restore `FailOpen` and remove the hot pod and the objectives:

```code
kubectl patch inferencepool vllm-qwen3-32b --type=merge -p '{"spec":{"endpointPickerRef":{"failureMode":"FailOpen"}}}'
kubectl delete -f 6.inferenceobjective.yaml -f 4.sim-hot-pod.yaml
```

> [!TIP]
> The GAIE **Flow Control** feature (`featureGates: ["flowControl"]` in the EndpointPickerConfig) goes further. It
> *queues* requests inside the EPP by priority and fairness ID (`x-gateway-inference-fairness-id` header) and does not
> drop them right away. See the [Flow Control guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/flow-control/).

---

## Part 9 - Model rollout with weighted InferencePools

**Scenario:** You have a new model version (or new vLLM version, or new GPU type) and want to send it 20% of
traffic first. This uses standard Gateway API **weighted backendRefs** (as in the traffic-splitting lab), but with
InferencePools as backends.

### 9.1 Deploy the v2 pool

```code
kubectl apply -f 7.canary/sim-v2.yaml
helm install vllm-qwen3-32b-v2 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.5.0 \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen3-32b-v2 \
  --set inferenceExtension.resources.requests.cpu=100m \
  --set inferenceExtension.resources.requests.memory=512Mi \
  --set inferenceExtension.resources.limits.memory=2Gi
kubectl rollout status deploy/vllm-qwen3-32b-v2
kubectl rollout status deploy/vllm-qwen3-32b-v2-epp
```

Each InferencePool has its **own** Endpoint Picker.

### 9.2 Split the traffic

```code
cat 7.canary/httproute-canary.yaml
kubectl apply -f 7.canary/httproute-canary.yaml
sleep 5
kubectl -n nginx-gateway logs deploy/ngf-nginx-gateway-fabric --since=30s | grep -E "successfully updated|Failed to update" | tail -1
```

```code
./tally.sh "" distinct 50 5 | awk '{n=$2; sub(/-[a-z0-9]+-[a-z0-9]+$/,"",n); a[n]+=$1} END {for (k in a) print a[k], k}'
```

```code
38 vllm-qwen3-32b
12 vllm-qwen3-32b-v2
```

About 80/20. NGF first picks a **pool** by weight, then that pool's EPP picks the best **pod**. To finish the
rollout, change the weights to 0/100.

Restore the original route and remove v2:

```code
kubectl apply -f 1.httproute.yaml
helm uninstall vllm-qwen3-32b-v2
kubectl delete -f 7.canary/sim-v2.yaml
```

---

## Part 10 - Beyond this lab: llm-d

This lab used the inference-aware routing of the Gateway API Inference Extension. The
[llm-d](https://llm-d.ai) project (CNCF Sandbox) builds on the same InferencePool / EPP model and adds:

| Feature | What it does | Why it matters |
|---------|--------------|----------------|
| **More scorers** | e.g. `no-hit-lru-scorer` for requests with no cache hit, precise prefix-cache scoring from vLLM KV-cache events | better cache hit rates at scale |
| **Prefill/decode disaggregation** | Prompt processing (prefill, compute bound) and token generation (decode, memory-bandwidth bound) run in separate pods that scale independently. The KV-cache is transferred between them over NIXL/NCCL. | a long prefill no longer blocks token streaming for other users. Each phase gets the right GPU type and replica count. |
| **Hierarchical KV-cache offload** (LMCache) | KV-cache is offloaded from GPU memory to CPU RAM and disk | long multi-turn conversations resume without recomputation |
| **Multi-node replicas** (LeaderWorkerSet) | one model replica across several nodes | models too big for one node |

The newer NGF documentation installs the **llm-d router** chart (`oci://ghcr.io/llm-d/charts/llm-d-router-gateway`)
instead of the GAIE `inferencepool` chart. The Gateway / HTTPRoute / InferencePool part stays the same: NGF remains
the gateway in front of the pool, whichever scheduler makes the decision.

**When is all of this not worth it?** With a single small model, one replica and low traffic there is nothing to
choose between, and a plain Service is fine. Inference-aware routing pays off with multiple replicas of large models,
shared prompt prefixes and uneven load. That is when GPUs are expensive and tail latency matters.

---

## Cleanup

```code
kubectl delete -f 7.canary/sim-v2.yaml --ignore-not-found
helm uninstall vllm-qwen3-32b-v2 2>/dev/null
kubectl delete -f 6.inferenceobjective.yaml -f 5.epp-metrics-rbac.yaml -f 4.sim-hot-pod.yaml --ignore-not-found
kubectl delete -f 3.httproute-baseline.yaml -f 2.service-baseline.yaml --ignore-not-found
kubectl delete -f 1.httproute.yaml -f 0.gateway.yaml --ignore-not-found
helm uninstall vllm-qwen3-32b
kubectl delete -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/refs/tags/v1.5.0/config/manifests/vllm/sim-deployment.yaml
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Route shows `Accepted=True` but traffic does not change | NGINX rejected the generated config and NGF rolled back. Check `kubectl -n nginx-gateway logs deploy/ngf-nginx-gateway-fabric \| grep "Failed to update"`. |
| `/rr` route returns `502` | The upstream has no servers after an earlier failed config. Delete and re-apply `3.httproute-baseline.yaml`. |
| Requests to the NodePort hang | Use the IP of the node that runs the NGINX pod (step 1.6). |
| Prefix requests are not sticky | Prompt shorter than 64 characters, the `prefix-cache-scorer` is not in the profile, or the EPP was not restarted after `helm upgrade`. |
| Hot pod still gets traffic through the InferencePool | Wait ~10 s for the EPP to scrape the new pod. Check that `metrics-data-source` and `core-metrics-extractor` are in the plugin list. |
| EPP `/metrics` returns `401` / `500` | No token / missing `system:auth-delegator` binding. Apply `5.epp-metrics-rbac.yaml`. |
| Batch requests are not dropped | The InferencePool is `FailOpen`. NGINX falls back to normal load balancing (Part 8). |
