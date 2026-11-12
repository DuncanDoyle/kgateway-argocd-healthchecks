# How health is decided (in depth)

This is the technical appendix to [`INSTALL.md`](INSTALL.md). It explains how ArgoCD's health states map to the Gateway API and kgateway status the checks read, and where that mapping stops.

## ArgoCD's health states

| State | Meaning | In a multi-step sync |
|---|---|---|
| `Healthy` | Working as intended | The next step may start |
| `Progressing` | Not there yet, may get there | The next step waits |
| `Degraded` | Failed | The sync fails |
| none | No health check for the kind | Never waits |

An Application shows its worst resource health, ignoring hooks and resources annotated `argocd.argoproj.io/ignore-healthcheck: "true"`. A sync is multi-step when it has more than one wave or phase (PreSync, PostSync), or an actual `PruneLast` prune. The last step does not wait for the health of its plain resources, but hooks are always waited on. "Sync waves" in `INSTALL.md` covers ordering.

## Which check covers which kind

| Kinds | Check | Status it reads |
|---|---|---|
| `Gateway`, `HTTPRoute`, `GRPCRoute` (ArgoCD 3.1+), more kinds in later releases | Bundled with ArgoCD | Gateway API status (below) |
| `TrafficPolicy`, `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse` | `ancestors` (this repo) | `status.ancestors[].conditions[]` |
| `Backend` | `conditions` (this repo) | `status.conditions[]` |
| `GatewayExtension`, `GatewayParameters` | none | kgateway writes no status ([kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792)); `GatewayParameters` status is unimplemented |
| `HTTPListenerPolicy` (v2.4.x only) | none | Deprecated in favour of `ListenerPolicy`, and removed in v2.5 |

## Gateway API kinds (ArgoCD's bundled checks)

These checks return at the first match, so order matters more than precedence. Each step checks `ResolvedRefs=False` → `Degraded`, then `Accepted=False` → `Degraded`, then a present `Programmed` that isn't `True` → `Progressing`.

| Kind | Steps, in order | Otherwise |
|---|---|---|
| `Gateway` | top-level conditions, then each listener | `Healthy` if it has conditions or listeners; `Progressing` if `status` is empty |
| `HTTPRoute`, `GRPCRoute` | each parent whose conditions match the current generation; stale parents are skipped | `Healthy` if a current parent has conditions; else `Progressing` |

A missing `Programmed` never causes `Progressing`. These checks don't filter parents by controller, and the `Gateway` check ignores generations. kgateway writes `kgateway.dev/Programmed` on routes, not `Programmed`, so the route checks never see it.

## The `ancestors` script

kgateway writes one ancestor per Gateway or `Backend` a policy reaches, each with `Accepted` and `Attached`. When a policy's target doesn't exist (v2.5+), it writes a synthetic `StatusSummary` ancestor instead. Only ancestors with `controllerName: kgateway.dev/kgateway` count.

Each `Accepted` or `Attached` condition on them is classified in this order:

| # | Condition | Counts as |
|---|---|---|
| 1 | stale (`observedGeneration` ≠ `metadata.generation`; never stale when either is absent) | `Progressing`, whatever its status |
| 2 | reason `Pending` (kgateway's default before it decides) | `Progressing` |
| 3 | reason `Invalid`, `PartiallyValid`, `Overridden` or `TargetNotFound` | `Degraded` |
| 4 | `status: True` | `Healthy` |
| 5 | `status: False`, any other reason | `Degraded` |

Then the results combine: any `Degraded` wins, then any `Progressing`, then any `Healthy`. One `True` condition is enough for `Healthy`; the script doesn't require both. With no owned ancestors, the verdict is `Progressing`, with one exception.

**`DirectResponse` exception.** A `DirectResponse` has no `targetRefs`. Routes reference it through an `ExtensionRef` filter, and it gets ancestors only through a route attached to a kgateway Gateway. With no owned ancestors it reads `Healthy` ("No attachment status reported by kgateway.dev/kgateway"), because an unused one is config, not pending work, and `Progressing` would stall any sync wave placed before its route. A referenced one still waiting for reconciliation reads the same.

## The `conditions` script (`Backend`)

`Accepted` and `EndpointsDiscovered` are classified in this order: stale counts as `Progressing`; `False` as `Degraded`; `True` as `Healthy`. They combine as above. `EndpointsDiscovered` is a runtime condition, so a `Backend` can be `Accepted=True` and still `Degraded`.

## Messages

`Degraded` and `Healthy` take the deciding condition's message. When that message is empty, the fallback is `<type>: <reason>`, `<type> is False` or `<type> is True`. `Progressing` always reads "Waiting for `<Kind>` status".

## Behaviour that depends on the kgateway version

| Situation | v2.4.x | v2.5.x |
|---|---|---|
| Policy whose target doesn't exist | no status → `Progressing` | `TargetNotFound` → `Degraded` |
| Policy whose target exists but isn't attached | no status → `Progressing` | no status → `Progressing` |
| `DirectResponse` used by nothing | no status → `Healthy` | no status → `Healthy` |

Before v2.3.0 kgateway wrote no `DirectResponse` status at all ([kgateway#13647](https://github.com/kgateway-dev/kgateway/pull/13647)), so every `DirectResponse` reads `Healthy` there. The fixtures cover v2.4.5 and v2.5.1.

## What the checks cannot see

- **What kgateway doesn't report.** A `ListenerPolicy` whose `caCertificateRefs` names a missing ConfigMap is `Accepted=True`, so it reads `Healthy`.
- **Other controllers.** Ancestors from other controllers are ignored, including their failures. A kgateway build with another controller name needs `CONTROLLER` changed in `healthchecks/lua/ancestors/health.lua`. The `conditions` script doesn't filter by controller.
- **Time.** A script sees one object and keeps no memory between evaluations. ArgoCD offers `os.time()`, but these scripts deliberately don't judge elapsed time: a verdict that flips with the clock alone would be hard to reason about. So a stuck controller looks the same as one that hasn't reconciled yet.
- **Traffic.** `Healthy` means the status the check reads meets the rules above. It doesn't prove attachment, and it doesn't prove requests succeed.
