# Failure scenarios

Each resource here is semantically wrong but structurally valid, so it passes
CRD admission and fails at translation. A manifest that admission rejects
produces no resource and therefore no status, which is the wrong failure mode.

Two of the three manifests in this directory differ from the original task
brief because the brief's draft did not survive contact with the live
cluster or the installed CRD schema. Both deviations were probed directly
before being committed — see below.

## Where each resource actually lives

| Resource | Namespace | Note |
|---|---|---|
| `TrafficPolicy/tp-target-missing` | `scenarios` | as designed |
| `Backend/backend-degraded` | `scenarios` | as designed (field name fixed, see below) |
| `TrafficPolicy/tp-degraded` | **`httpbin`** | moved — see "Cross-namespace targeting" below |

`kubectl -n scenarios get trafficpolicy,backend` only ever shows two of the
three tracked scenario resources (`tp-target-missing`, `backend-degraded`).
`tp-degraded` must be looked up in `httpbin`. Anyone scripting a status
check against "the scenarios namespace" needs to know this.

## Deviation 1: cross-namespace TrafficPolicy targeting is impossible

The brief's original `trafficpolicy-degraded.yaml` put an HTTPRoute
(`scenarios-route`) in namespace `scenarios` with a `parentRef` reaching
across to `demo-gateway` in `httpbin`, and a `TrafficPolicy` in `scenarios`
targeting that route.

Probed directly before writing the final manifest:

1. Applied the cross-namespace HTTPRoute standalone. The demo Gateway's
   listener (`allowedRoutes.namespaces.from: Same`) rejected it:
   `status.parents[0].conditions`: `Accepted=False`,
   `reason=NotAllowedByListeners`. This confirms the risk the brief flagged
   inline.
2. Checked the TrafficPolicy CRD's `targetRefs` schema
   (`kubectl get crd trafficpolicies.gateway.kgateway.dev -o json`). The
   target entry has only `group`, `kind`, `name`, `sectionName` — **no
   namespace field** — and its description states "The object must be in
   the same namespace as the policy." So even with a `ReferenceGrant`, a
   `TrafficPolicy` in `scenarios` structurally cannot target anything
   outside `scenarios`. This is a harder constraint than the Gateway's
   `allowedRoutes`, and it isn't configuration-dependent.

**Applied fallback:** `TrafficPolicy/tp-degraded` is created directly in
namespace `httpbin`, targeting the existing `httpbin-via-service` HTTPRoute
from Task 3. The `scenarios-route` HTTPRoute was dropped entirely rather
than kept as a deliberately-broken, unattached artifact — it added no
signal once the cross-namespace attach was confirmed impossible. The
degraded mechanism under test (`extAuth.extensionRef` → non-existent
`GatewayExtension`) is unchanged.

**Consequence — does this perturb the demo namespace?** Yes, structurally:
syncing `kgw-scenarios` adds a resource into `httpbin`, a namespace it does
not own by `destination.namespace` (that's `scenarios`). ArgoCD permits
this because the default `AppProject` allows `namespace: '*'`, and the
resource carries its own `argocd.argoproj.io/tracking-id` pointing at
`kgw-scenarios`, so it does not show up as unmanaged/out-of-sync for either
Application. Checked directly: `kgw-demo` (the app that owns `httpbin`)
still reports `Synced Healthy` after `kgw-scenarios` synced — it is not
flagged out-of-sync, because its own manifest set didn't change. But the
namespace itself now contains a resource `kgw-demo` never created, which
matters if Task 5 or later tasks assume `httpbin` only ever holds `kgw-demo`
resources.

**Does the pre-existing healthy policy on the same route degrade?**
Checked explicitly — `add-demo-header` (Task 3's healthy TrafficPolicy,
also targeting `httpbin-via-service`) after `tp-degraded` exists:

```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: demo-gateway
      namespace: httpbin
    conditions:
    - type: Accepted
      status: "True"
      reason: Valid
      message: Policy accepted
    - type: Attached
      status: "True"
      reason: Attached
      message: Attached to all targets
    controllerName: kgateway.dev/kgateway
```

Unaffected — still `Accepted=True/Valid`, `Attached=True/Attached`. kgateway
evaluates each TrafficPolicy attached to a route independently; a second,
broken policy on the same target does not drag the first one's status down.
Task 5's Healthy fixture is not at risk from this.

## Deviation 2: `Backend` CRD field name

The brief's `backend-degraded.yaml` used `priorityGroups[].backends[].name`.
The installed Backend CRD (kgateway v2.4.5) has no `backends` field under
`priorityGroups[]` — the actual (and required, `minItems: 1`) field is
`backendRefs`. Using `backends` would have left `priorityGroups[0]` with no
`backendRefs` at all, failing CRD schema validation and getting the whole
resource rejected at admission — exactly the "wrong failure mode" Step 7
warns about. Fixed to `backendRefs`; the semantic intent (reference a
`Backend` name that does not exist) is unchanged.

## Observed status

| Resource | Mechanism | Predicted | Observed |
|---|---|---|---|
| `TrafficPolicy/tp-target-missing` | targets a non-existent HTTPRoute | no ancestors → Progressing | **Confirmed on v2.4.5.** On v2.5.1 it is `Accepted=False/TargetNotFound` → Degraded instead; see [COVERAGE.md](COVERAGE.md#what-changed-on-v251). `status` field is entirely absent from the object (`kubectl get ... -o jsonpath='{.status}'` returns empty) — not an empty `ancestors: []`, but no `status` key at all. A health check keying off "no ancestors" must treat a *missing* `status` the same as an empty `ancestors` list. |
| `TrafficPolicy/tp-degraded` | `extAuth.extensionRef` → non-existent GatewayExtension | `Accepted=False/Invalid` → Degraded | **Confirmed, plus an extra condition.** `status.ancestors[0].conditions`: `Accepted=False/reason=Invalid`, message `'extauth: httpbin/no-such-gateway-extension: gateway extension not found'`. There is also a second condition, `Attached=False/reason=Pending`, message `""`. The brief only predicted the Accepted condition; Attached staying `Pending` (never evaluated) because Accepted never becomes true is a real, additional observation — see the Pending probe below. |
| `Backend/backend-degraded` | priority group → non-existent Backend | `Accepted=False/Invalid` → Degraded | **Confirmed.** `status.conditions[0]`: `Accepted=False/reason=Invalid`, message `'Backend error: "priority group 0: backend "no-such-backend" not found in namespace "scenarios""'`. |

Complete status YAML for all three, captured via `kubectl get -o yaml`, is
inlined below (not linked to a path — the original `out/probe/` scratch
captures were never tracked and `out/` is gitignored by design; see
`docs/evidence/` for other committed captures).

### `TrafficPolicy/tp-degraded` full status

```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: demo-gateway
      namespace: httpbin
    conditions:
    - lastTransitionTime: "2026-09-23T17:26:52Z"
      message: 'extauth: httpbin/no-such-gateway-extension: gateway extension not
        found'
      observedGeneration: 1
      reason: Invalid
      status: "False"
      type: Accepted
    - lastTransitionTime: "2026-09-23T17:26:52Z"
      message: ""
      observedGeneration: 1
      reason: Pending
      status: "False"
      type: Attached
    controllerName: kgateway.dev/kgateway
```

### `Backend/backend-degraded` full status

```yaml
status:
  conditions:
  - lastTransitionTime: "2026-09-23T17:26:52Z"
    message: 'Backend error: "priority group 0: backend "no-such-backend" not found
      in namespace "scenarios""'
    observedGeneration: 1
    reason: Invalid
    status: "False"
    type: Accepted
```

### `TrafficPolicy/tp-target-missing` full status

On v2.4.5: empty — the object has no `status` field at all after creation
and after the watch window. On v2.5.1: see
`healthchecks/lua/TrafficPolicy/testdata/target_missing.yaml`.

## `Accepted=False/Reason=Pending` probe

The brief's open question: is `Accepted=False/Reason=Pending` ever
observable? Ran the watch (`kubectl -n httpbin get trafficpolicy -o yaml
--watch`, adjusted from `scenarios` to `httpbin` since `tp-degraded` lives
there — see Deviation 1) while patching `tp-degraded`'s spec 5 times over 5
seconds to force re-reconciliation. The original capture lived only in
`out/probe/` (gitignored, never tracked) — re-run live against the same
cluster on 2026-09-24 to produce a committed excerpt:
[`docs/evidence/tp-watch-pending-probe.txt`](docs/evidence/tp-watch-pending-probe.txt).

**`reason: Pending` count: 13 occurrences in the re-run (watch-event count
varies run to run — each patch can surface more than one update event; the
original run counted 11 across the same 1 initial + 5 forced
reconciliations). All occurrences, in both runs, are on `type: Attached`;
zero are on `type: Accepted`.**

So, precisely answering the brief's question as posed —
`Accepted=False/Reason=Pending` — the count is **0**. It was never observed
on the `Accepted` condition in this probe. `Accepted` for `tp-degraded` was
`False/Invalid` throughout every watch event (initial state through all 5
patches); it never transitioned through a `Pending` reason on that
condition.

What *was* observed repeatedly is `Attached=False/reason=Pending` — every
single watch event for `tp-degraded` carries this. The pattern: once
`Accepted` is `False`, `Attached` is never evaluated and stays parked at
`Pending` with an empty message. This is consistent with attachment
evaluation being gated behind acceptance succeeding first.

**Consequence for Task 7 (Lua health check):** the health check should not
expect to find `Pending` on `Accepted` for TrafficPolicy — this probe found
zero instances of that combination across 6 reconciliation events (1
initial + 5 forced). If the Lua script has a defensive branch for
`Accepted=False/Reason=Pending`, this probe gives no evidence it is
reachable and **no fixture should be fabricated to exercise it**.

`Attached=False/Reason=Pending` is not rare, though — it's the steady state
of a policy whose extension reference never resolves, so the script must
still handle it correctly. The shipped script treats `Pending` as
**Progressing** on whichever condition carries it, matching the reason's own
"seen, not yet decided" semantics — it does not special-case
`Attached=False/Pending` as Degraded. That is still the right overall
verdict for `tp-degraded`: with precedence Degraded > Progressing > Healthy,
the co-occurring `Accepted=False/Invalid` condition independently produces
Degraded, and Degraded wins regardless of what `Attached` says. Mapping
`Pending` itself to Degraded would be wrong in general — it would false-alarm
on a policy that is genuinely mid-attachment with no failure at all.

## ArgoCD's own health assessment (context for Task 7)

For reference, `kubectl -n argocd get application kgw-scenarios` reports
`Synced Healthy` throughout — with all three scenario resources in a
translation-failed state. ArgoCD has no built-in health check for
`TrafficPolicy` or `Backend` CRDs, so it defaults to treating them as
healthy. This is the gap the demo exists to illustrate, confirmed live:
default ArgoCD shows a false "Healthy" for a Backend and TrafficPolicy that
are both rejected at translation, and for a TrafficPolicy with no status at
all.

## If a prediction did not hold

All three status predictions held once the manifests were corrected for
the two structural issues above (cross-namespace targeting, `Backend`
field name) — those corrections are the actual finding here, not a status
surprise. The one genuinely open question the brief flagged, whether
`Accepted=False/Reason=Pending` is reachable, resolved to **not observed
(0 occurrences)** in this probe; `Attached=False/Reason=Pending` is
reachable and common instead.
