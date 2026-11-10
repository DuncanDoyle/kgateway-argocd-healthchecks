# Running the demo

Everything on this page assumes `./setup.sh` has finished. That installs the Gateway API CRDs, kgateway and ArgoCD into your current kube-context.

## What this demo deploys

Three ArgoCD Applications. They look alike in the UI but do quite different jobs, and **only the first is meant to be shown to an audience**:

| Application | Manifests | What it is for |
|---|---|---|
| `kgw-demo` | `manifests/demo/` | The demo itself — a Gateway, an httpbin workload, two HTTPRoutes, a `Backend` and a `TrafficPolicy`. All healthy. |
| `kgw-coverage` | `manifests/coverage/` | Test scaffolding, not a demo. It creates `ListenerPolicy`, `BackendConfigPolicy` and `DirectResponse` resources in assorted health states, purely so the fixture-capture scripts have real status to copy out of a real cluster. Nothing here has a story; skip it if you only want to run the demo. |
| `kgw-scenarios` | `manifests/scenarios/` | Deliberately broken resources, so the UI shows Degraded and Progressing badges next to the healthy ones. |

Apply them in the order below. `kgw-coverage` and `kgw-scenarios` both attach to a Gateway and land in a namespace that `kgw-demo` creates, so applied earlier they have nothing to attach to.

**If you are only here to capture fixtures** rather than to demo anything, you still need all three — see [README.md](README.md#verifying-the-health-checks).

## Before you start

- `jq` — used by the verification commands below.
- The `argocd` CLI is **optional**; see "Syncing an Application" below.

### Syncing an Application

`kgw-demo` syncs itself (its `syncPolicy` is `automated`). The coverage and scenarios Applications are deliberately manual, so each needs an explicit sync. Three ways, in order of how little can go wrong:

```bash
# 1. kubectl only — no login, no port-forward, no CLI
kubectl -n argocd patch application kgw-coverage --type merge -p '{"operation":{"sync":{}}}'

# 2. The UI — press Sync on the Application

# 3. The argocd CLI, which must log in first
argocd login --port-forward --port-forward-namespace argocd --plaintext --username admin
argocd app sync kgw-coverage --port-forward --port-forward-namespace argocd --plaintext
```

Option 1 is what the steps below use. ArgoCD exposes sync as a field on the Application (`operation`), so a patch is a first-class trigger, not a workaround.

**If `argocd app sync` hangs with no output, you are not logged in.** The CLI falls back to whatever `current-context` is in `~/.config/argocd/config` — possibly a server from months ago — and blocks on the TCP connect until it times out. Check with `argocd context`, and note that `argocd login` is what sets that context.

Use `--port-forward --port-forward-namespace argocd` rather than logging in through your own `kubectl port-forward`: the CLI's gRPC connection can make `argocd-server` reset the forwarded connection, which kills the whole port-forward with `error: lost connection to pod`. Letting the CLI manage its own forward avoids that. `--plaintext` is needed because `setup.sh` runs the server with `server.insecure: true`.

One confusing error worth knowing: `argocd app sync` on an Application that does not exist returns **`permission denied`**, not "not found". If you see it, check `argocd app list` before assuming an RBAC problem.

Each `kubectl apply` below pipes the Application manifest through `sed` to substitute `REPO_URL` and `REPO_REVISION` from [`env.sh`](env.sh), which is where this repo pins the git source ArgoCD pulls from. Kubernetes manifests do not expand shell variables, hence the pipe.

## 1. Deploy the demo

```bash
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-demo.yaml | kubectl apply -f -
```

Open the ArgoCD UI on <http://localhost:8081>. It deliberately does not use 8080 — the Gateway forward in step 5 takes that port, and you want both running at once.

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8081:80
# user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The `kgw-demo` Application tree shows the Gateway, both HTTPRoutes, the `Backend` and the `TrafficPolicy`. Note that `Backend` and `TrafficPolicy` show **no health status** — that is the gap this repo exists to close.

Wait for it to go Healthy before continuing, since the next two Applications depend on what it creates:

```bash
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/kgw-demo --timeout=180s
```

## 2. Install the health checks

This is the point of the repo. The checks are five Lua scripts delivered as a patch to ArgoCD's `argocd-cm` ConfigMap — exactly what an end user applies, with no dependency on this demo. [docs/INSTALL.md](docs/INSTALL.md) is the user-facing version of this step.

```bash
kubectl -n argocd patch configmap argocd-cm \
  --patch-file healthchecks/argocd-cm-patch.yaml

# Applications cache per-resource health and ignore an argocd-cm change until
# refreshed, so the badges stay blank for minutes otherwise. Force it:
for a in kgw-demo kgw-coverage kgw-scenarios; do
  kubectl -n argocd annotate application "$a" \
    argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null
done
```

Within a few seconds the two resources that showed nothing in step 1 have health. In the UI they gain icons; from the CLI:

```bash
kubectl -n argocd get application kgw-demo \
  -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" -> "}{.health.status}{"\n"}{end}'
```

```
Backend/httpbin-static       -> Healthy
TrafficPolicy/add-demo-header -> Healthy
```

ArgoCD reads `argocd-cm` live, so nothing needs restarting. The CLI command above works because `setup.sh` set `controller.resource.health.persist: "true"` — without it the UI badges still appear but this `jsonpath` prints empty for every resource, which looks identical to a failed install. [README.md](README.md#why-health-does-not-show-up-in-kubectl) explains why.

**To show the before/after again**, remove the keys and hard-refresh:

```bash
for k in TrafficPolicy ListenerPolicy BackendConfigPolicy DirectResponse Backend; do
  kubectl -n argocd patch cm argocd-cm --type=json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/resource.customizations.health.gateway.kgateway.dev_${k}\"}]"
done
```

`hack/capture-evidence.sh` automates exactly this round trip and asserts both states — see [hack/README.md](hack/README.md).

Everything deployed from here on picks up the checks automatically.

## 3. Deploy the coverage resources

Only needed if you intend to run the fixture-capture scripts (`hack/extract-testdata.sh`, `hack/check-generated.sh`, `hack/capture-evidence.sh`). They read these resources' status straight out of the cluster, so without this Application they fail on the first one they cannot find. Those scripts need **step 4 as well** — two of the twelve refreshed fixtures come from the scenarios resources.

```bash
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-coverage.yaml | kubectl apply -f -
kubectl -n argocd patch application kgw-coverage --type merge -p '{"operation":{"sync":{}}}'
```

[COVERAGE.md](COVERAGE.md) lists each resource, what it is supposed to prove, and the status it actually produced — including two that did not behave as predicted.

## 4. Show the failure scenarios

```bash
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-scenarios.yaml | kubectl apply -f -
kubectl -n argocd patch application kgw-scenarios --type merge -p '{"operation":{"sync":{}}}'
```

With the checks installed in step 2, these are the badges worth showing — the demo so far has been uniformly green:

```bash
kubectl -n argocd get application kgw-scenarios \
  -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" -> "}{.health.status}{"\n"}{end}'
```

```
Backend/backend-degraded  -> Degraded
TrafficPolicy/tp-degraded -> Degraded
TrafficPolicy/tp-target-missing -> Degraded
```

Hover the badge in the UI for the message: each carries kgateway's own rejection reason. `tp-target-missing` targets an HTTPRoute that does not exist; on kgateway v2.4.x it shows `Progressing` instead, because that line writes no status for it.

See [SCENARIOS.md](SCENARIOS.md) for what each resource is meant to show — and note that one of the three lives in the `httpbin` namespace rather than `scenarios`, for reasons that file explains.

## 5. Prove the data path

Leave the ArgoCD port-forward from step 1 running; this one uses a different local port, so the two do not collide.

```bash
kubectl -n httpbin port-forward svc/demo-gateway 8080:8080
curl -s localhost:8080/headers      | jq '.headers["X-Kgateway-Demo"]'
curl -s localhost:8080/via-backend  | jq '.headers["X-Kgateway-Demo"]'
```

`/headers` routes through the Service and has the `TrafficPolicy` attached, so the injected header comes back. `/via-backend` routes through the `Backend` CR with no policy attached, so it does not.
