# Coverage probe: observed status on kgateway v2.4.5 and v2.5.1

Everything below was observed on a live cluster, not predicted. The probe ran on v2.4.5 (minikube `kgw-argocd`) and was repeated on v2.5.1 (minikube `kgw-argocd-25`). `GatewayExtension` is out of scope: it writes no status on either version (re-checked on v2.5.1 with a valid and an invalid instance). Manifests are in `manifests/coverage/`; the Application is `argocd/app-coverage.yaml`.

## What changed on v2.5.1

One behaviour changed. A policy whose target does not exist now gets a synthetic `StatusSummary` ancestor with `Accepted=False/TargetNotFound` and `Attached=False/TargetNotFound` (message e.g. "Gateway httpbin/no-such-gateway not found"). On v2.4.5 it got no `status` at all. The health check therefore reports **Degraded** on v2.5.x and **Progressing** on v2.4.x. Both are tested: `target_missing.yaml` is the v2.5.1 capture, `target_missing_v2_4.yaml` the v2.4.5 one.

The other 10 live captures came back byte-identical, apart from volatile fields. `lp-target-missing` was named `lp-unattached` during the v2.4.5 probe; the sections below use the current name.

## A DirectResponse with no status

A `DirectResponse` has no `targetRefs`. An `HTTPRoute` rule references it through an `ExtensionRef` filter, and kgateway writes its `Accepted`/`Attached` ancestors only once such a route is attached to a kgateway Gateway. With no ancestors from our controller, the check reports **Healthy** with "No attachment status reported by kgateway.dev/kgateway". The policy kinds keep reporting Progressing in the same situation.

Why the exception:

- An unused `DirectResponse` is config, not pending work. A maintenance page kept in Git, or one defined before its route, is legitimate.
- Progressing would stall a multi-step sync. ArgoCD waits for a Progressing resource before applying the next wave, so a `DirectResponse` placed before the route that uses it would never let that route deploy.
- argo-cd's bundled Crossplane check does the same for referenced config kinds that never get conditions, such as `ProviderConfig`.

What it does not mean: Healthy here proves no acceptance, attachment or working traffic. It also can't see a stuck controller. An owned ancestor that is pending, stale or missing conditions still reads Progressing, and a rejection still reads Degraded. kgateway before v2.3 never reports `DirectResponse` status ([kgateway#13647](https://github.com/kgateway-dev/kgateway/pull/13647)), so there every `DirectResponse` takes this path. The six boundary cases are fixtures under `healthchecks/lua/DirectResponse/testdata/`.

## CRD spec fields (Step 1)

- ListenerPolicy: `default, perPort, targetRefs, targetSelectors`
- BackendConfigPolicy: `circuitBreakers, commonHttpProtocolOptions, connectTimeout, dns, healthCheck, http1ProtocolOptions, http2ProtocolOptions, loadBalancer, outlierDetection, perConnectionBufferLimitBytes, targetRefs, targetSelectors, tcpKeepalive, tls, upstreamProxyProtocol` (`tls.secretRef` exists)
- DirectResponse: `body, bodyFormat, status`

## Predicted vs observed

| Resource | Predicted | Observed |
|---|---|---|
| ListenerPolicy `lp-healthy` | Accepted+Attached True | As predicted. Ancestor Gateway `httpbin/demo-gateway`. |
| ListenerPolicy `lp-target-missing` (targets nonexistent Gateway) | No status | **No `status` field at all**, still none after 60s+. (v2.5.1: `Accepted=False/TargetNotFound`, see above.) |
| ListenerPolicy `lp-degraded-ca` (caCertificateRefs to a missing ConfigMap) | Degraded | **Not Degraded**: `Accepted=True/Valid`, `Attached=True/Attached`. |
| ListenerPolicy `lp-degraded-accesslog` (accessLog grpcService backendRef to a missing Service) | Degraded | **Degraded**: `Accepted=False/Invalid` ("unresolved backend reference: Service httpbin/no-such-log-service not found"), `Attached=False/Pending` (empty message). Ancestor Gateway `coverage-gateway-log`. |
| BackendConfigPolicy `bcp-healthy` | Accepted+Attached True | As predicted. Ancestor is the **Backend** `httpbin/coverage-backend` (`group: gateway.kgateway.dev`), not a Gateway. |
| BackendConfigPolicy `bcp-degraded` (tls.secretRef to a missing Secret) | Degraded | **Degraded**: `Accepted=False/Invalid` ("failed to extract TLS data: Secret httpbin/no-such-tls-secret not found"), `Attached=False/Pending`. |
| DirectResponse `dr-healthy` | Accepted+Attached True | As predicted. Ancestor is Gateway `demo-gateway` (not the referencing HTTPRoute). |
| DirectResponse `dr-unreferenced` | No status | **No `status` field at all**, still none after 60s+. |

Not tried for DirectResponse: a route referencing it whose parent Gateway does not exist (optional candidate, skipped). "No Degraded reachable" is therefore established for DirectResponse only for the one mechanism tried.

## Blocking question: do the three kinds carry Accepted + Attached against a Gateway ancestor?

All three write `status.ancestors[]` with `controllerName: kgateway.dev/kgateway` and condition types `Accepted` and `Attached`; healthy reasons are `Valid` and `Attached`. Unhealthy reasons are `Invalid` (Accepted) and `Pending` (Attached, empty message). Ancestor kind: **Gateway** for ListenerPolicy and DirectResponse; **Backend** for BackendConfigPolicy. Whether the shared ancestors script copes with a Backend ancestor and with `Invalid`/`Pending` is for Tasks 3/4 to check before reusing it unchanged.

## Findings

1. **A failing policy surfaces on the status of its target, not only on the policy.**
   - BackendConfigPolicy: with `bcp-degraded` targeting the demo's `Backend/httpbin-static`, that Backend went `Accepted=False/Invalid` (`Backend error: "gateway.kgateway.dev/BackendConfigPolicy/httpbin/bcp-degraded: failed to extract TLS data: ..."`), `kgw-demo` went Degraded and the source of the tracked `Backend/testdata/healthy.yaml` was corrupted. After the fix synced, `httpbin-static` returned to `Accepted=True/Accepted`, "Backend accepted", `observedGeneration: 21`, identical to the tracked fixture apart from `lastTransitionTime`.
   - ListenerPolicy: the same happens to Gateways. `lp-degraded-accesslog` put its target `coverage-gateway-log` into `Accepted=False/GatewayReplaced` with the policy's message, while `Programmed` stayed True. The Argo health check reports the Gateway Degraded with that message. **Coverage resources must never target demo resources** (the first manifests did, and were fixed with `coverage-backend` and dedicated Gateways).
   - The error is per target, not per policy: `bcp-healthy` stays Accepted+Attached True while `coverage-backend` itself is `Accepted=False/Invalid` because of its sibling.
2. **Contrast between two reference fields.** A missing Secret in BackendConfigPolicy `tls.secretRef` and a missing Service in ListenerPolicy `accessLog[].grpcService.backendRef` are rejected (`Invalid`). A missing ConfigMap in ListenerPolicy `clientCertificateValidation.caCertificateRefs` is **accepted** (`Valid`/`Attached`). Two reference-type fields, two behaviours. Whether that is a kgateway bug is not decided here.
3. **Port 8082 is reserved by kgateway.** A Gateway listener on 8082 came out `Programmed=False/Invalid` with `invalid port 8082 in listener: port is reserved`; a ListenerPolicy targeting it got no status at all. Avoid 8082 in any extension of this demo.
4. **Unattached and unreferenced resources get no status** (`lp-target-missing`, `dr-unreferenced`): the controller writes ancestors only once something attaches. That looks correct, not a bug. For the policy kinds the health script treats an absent status as Progressing. `DirectResponse` is the exception; see "A DirectResponse with no status" below. On v2.5.1 `dr-unreferenced` still gets no status, but a missing policy target now reports `TargetNotFound`.
5. **Degraded is reachable for ListenerPolicy** (accesslog backendRef) and BackendConfigPolicy. For DirectResponse, no Degraded was reached with the single mechanism tried.
6. **`kgw-coverage` is Synced/Degraded**, not Healthy. The Degraded comes from the *existing* Backend and Gateway health checks seeing `Backend/coverage-backend` (policy error) and `Gateway/coverage-gateway-log` (policy error). The three new kinds have no health check yet and show blank health (`BackendConfigPolicy`, `DirectResponse`, `ListenerPolicy` resources all have empty health in the Application resource list). `kgw-demo` is Synced/Healthy; `kgw-scenarios` is Synced/Degraded.

## Fixtures: capture source per kind

Name each fixture file after the state actually captured. Capture the **policy** resource for the policy-kind fixtures. Backend/Gateway are only needed for the existing Backend/Gateway checks, not the new ones.

| Kind | Healthy fixture, from | Degraded fixture, from | No-status fixture, from |
|---|---|---|---|
| ListenerPolicy | `httpbin/lp-healthy` | `httpbin/lp-degraded-accesslog` (NOT `lp-degraded-ca`, which is Accepted/Valid) | `httpbin/lp-target-missing` |
| BackendConfigPolicy | `httpbin/bcp-healthy` | `httpbin/bcp-degraded` (the policy; `Backend/coverage-backend` carries the surfaced error but is a Backend-kind fixture, not a BackendConfigPolicy one) | none observed |
| DirectResponse | `httpbin/dr-healthy` | none reachable | `httpbin/dr-unreferenced` |

`httpbin/lp-degraded-ca` is an additional healthy-looking capture (Accepted/Valid with a dangling reference) if a fixture for that contrast is wanted. Never capture from `Backend/httpbin-static` or `Gateway/demo-gateway` for coverage purposes.

## Complete observed status (post-fix, `ca05559`)

### listenerpolicy/lp-healthy
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: demo-gateway
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:17:07Z"
      message: Policy accepted
      observedGeneration: 1
      reason: Valid
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:17:07Z"
      message: Attached to all targets
      observedGeneration: 1
      reason: Attached
      status: "True"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### listenerpolicy/lp-target-missing
```yaml
# (no status field on v2.4.5; see testdata/target_missing.yaml for v2.5.1)
```

### listenerpolicy/lp-degraded-ca
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: coverage-gateway-ca
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Policy accepted
      observedGeneration: 1
      reason: Valid
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Attached to all targets
      observedGeneration: 1
      reason: Attached
      status: "True"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### listenerpolicy/lp-degraded-accesslog
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: coverage-gateway-log
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:25:52Z"
      message: 'unresolved backend reference: Service httpbin/no-such-log-service
        not found'
      observedGeneration: 1
      reason: Invalid
      status: "False"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:25:52Z"
      message: ""
      observedGeneration: 1
      reason: Pending
      status: "False"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### gateway/coverage-gateway-log
```yaml
status:
  conditions:
  - lastTransitionTime: "2026-10-07T08:25:52Z"
    message: 'unresolved backend reference: Service httpbin/no-such-log-service not
      found'
    observedGeneration: 2
    reason: GatewayReplaced
    status: "False"
    type: Accepted
  - lastTransitionTime: "2026-10-07T08:25:52Z"
    message: Successfully programmed Gateway
    observedGeneration: 2
    reason: Programmed
    status: "True"
    type: Programmed
  - lastTransitionTime: "2026-10-07T08:24:05Z"
    message: Successfully resolved all Gateway references
    observedGeneration: 2
    reason: ResolvedRefs
    status: "True"
    type: ResolvedRefs
  listeners:
  - attachedRoutes: 0
    conditions:
    - lastTransitionTime: "2026-10-07T08:25:52Z"
      message: Successfully accepted Listener
      observedGeneration: 2
      reason: Accepted
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:25:52Z"
      message: Successfully verified that Listener has no conflicts
      observedGeneration: 2
      reason: NoConflicts
      status: "False"
      type: Conflicted
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Successfully resolved all references
      observedGeneration: 2
      reason: ResolvedRefs
      status: "True"
      type: ResolvedRefs
    - lastTransitionTime: "2026-10-07T08:25:52Z"
      message: Successfully programmed Listener
      observedGeneration: 2
      reason: Programmed
      status: "True"
      type: Programmed
    name: http
    supportedKinds:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
    - group: gateway.networking.k8s.io
      kind: GRPCRoute
```

### gateway/coverage-gateway-ca
```yaml
status:
  conditions:
  - lastTransitionTime: "2026-10-07T08:24:05Z"
    message: Successfully accepted Gateway
    observedGeneration: 1
    reason: Accepted
    status: "True"
    type: Accepted
  - lastTransitionTime: "2026-10-07T08:24:05Z"
    message: Successfully programmed Gateway
    observedGeneration: 1
    reason: Programmed
    status: "True"
    type: Programmed
  - lastTransitionTime: "2026-10-07T08:24:05Z"
    message: Successfully resolved all Gateway references
    observedGeneration: 1
    reason: ResolvedRefs
    status: "True"
    type: ResolvedRefs
  listeners:
  - attachedRoutes: 0
    conditions:
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Successfully accepted Listener
      observedGeneration: 1
      reason: Accepted
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Successfully verified that Listener has no conflicts
      observedGeneration: 1
      reason: NoConflicts
      status: "False"
      type: Conflicted
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Successfully resolved all references
      observedGeneration: 1
      reason: ResolvedRefs
      status: "True"
      type: ResolvedRefs
    - lastTransitionTime: "2026-10-07T08:24:05Z"
      message: Successfully programmed Listener
      observedGeneration: 1
      reason: Programmed
      status: "True"
      type: Programmed
    name: http
    supportedKinds:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
    - group: gateway.networking.k8s.io
      kind: GRPCRoute
```

### backendconfigpolicy/bcp-healthy
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.kgateway.dev
      kind: Backend
      name: coverage-backend
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:20:05Z"
      message: Policy accepted
      observedGeneration: 2
      reason: Valid
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:20:05Z"
      message: Attached to all targets
      observedGeneration: 2
      reason: Attached
      status: "True"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### backendconfigpolicy/bcp-degraded
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.kgateway.dev
      kind: Backend
      name: coverage-backend
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:20:05Z"
      message: 'failed to extract TLS data: Secret httpbin/no-such-tls-secret not
        found'
      observedGeneration: 2
      reason: Invalid
      status: "False"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:20:05Z"
      message: ""
      observedGeneration: 2
      reason: Pending
      status: "False"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### backend/coverage-backend
```yaml
status:
  conditions:
  - lastTransitionTime: "2026-10-07T08:20:05Z"
    message: 'Backend error: "gateway.kgateway.dev/BackendConfigPolicy/httpbin/bcp-degraded:
      failed to extract TLS data: Secret httpbin/no-such-tls-secret not found"'
    observedGeneration: 1
    reason: Invalid
    status: "False"
    type: Accepted
```

### backend/httpbin-static
```yaml
status:
  conditions:
  - lastTransitionTime: "2026-10-07T08:20:04Z"
    message: Backend accepted
    observedGeneration: 21
    reason: Accepted
    status: "True"
    type: Accepted
```

### directresponse/dr-healthy
```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: demo-gateway
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-10-07T08:17:06Z"
      message: Policy accepted
      observedGeneration: 1
      reason: Valid
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:17:06Z"
      message: Attached to all targets
      observedGeneration: 1
      reason: Attached
      status: "True"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### directresponse/dr-unreferenced
```yaml
# (no status field)
```

### httproute/coverage-directresponse
```yaml
status:
  parents:
  - conditions:
    - lastTransitionTime: "2026-10-07T08:17:06Z"
      message: Successfully accepted Route
      observedGeneration: 1
      reason: Accepted
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-10-07T08:17:06Z"
      message: Successfully resolved all references
      observedGeneration: 1
      reason: ResolvedRefs
      status: "True"
      type: ResolvedRefs
    - lastTransitionTime: "2026-10-07T08:17:06Z"
      message: Successfully programmed Route
      observedGeneration: 1
      reason: Programmed
      status: "True"
      type: kgateway.dev/Programmed
    controllerName: kgateway.dev/kgateway
    parentRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: demo-gateway
```

