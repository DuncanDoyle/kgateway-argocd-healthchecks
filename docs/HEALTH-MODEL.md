# How health is decided (in depth)

This is the technical appendix to [`INSTALL.md`](INSTALL.md). It explains how the checks turn the status kgateway writes into an ArgoCD health state, and where that mapping stops.

## ArgoCD's health states

| State | What ArgoCD means by it | Effect on the Application | Effect in a multi-step sync |
|---|---|---|---|
| `Healthy` | Working as intended | None | The next step may start |
| `Progressing` | Not there yet, may get there | The Application shows `Progressing`, unless something is `Degraded` | The next step waits |
| `Degraded` | Failed | The Application shows `Degraded` | The sync fails |
| none | No health check for the kind | Ignored | Never waits |

The Application shows its worst resource. A sync has multiple steps when it has more than one wave, a PostSync hook, or an actual `PruneLast` prune. The last step does not wait for health. The section "Sync waves" in `INSTALL.md` covers ordering.

## Which check covers which kind

| Group | Kinds | Check | Status it reads |
|---|---|---|---|
| `gateway.networking.k8s.io` | `Gateway`, `HTTPRoute`, `GRPCRoute`, and more per release | Bundled with ArgoCD: 3 kinds in 3.3, 5 in 3.5, 7 in 3.6, none in 2.x or 3.0 | Gateway API status |
| `gateway.kgateway.dev` | `TrafficPolicy`, `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse` | This repo, `ancestors` script | `status.ancestors[].conditions[]` |
| `gateway.kgateway.dev` | `Backend` | This repo, `conditions` script | `status.conditions[]` |
| `gateway.kgateway.dev` | `GatewayExtension`, `GatewayParameters` | None | kgateway writes no status ([kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792); `GatewayParameters` status is unimplemented) |

Every script reads only `obj` and returns a verdict. It has no history and no clock: `argocd-cm` scripts get no `string`, `math` or real `os` library.

## The `ancestors` script

kgateway writes one ancestor per Gateway (or `Backend`) the policy reaches. Each carries `Accepted` and `Attached`. The script reads only ancestors with `controllerName: kgateway.dev/kgateway`, and evaluates every `Accepted` and `Attached` condition on them:

| Condition on an owned ancestor | Verdict |
|---|---|
| `observedGeneration` ≠ `metadata.generation` | `Progressing` |
| reason `Pending` (kgateway's default before it decides) | `Progressing` |
| reason `Invalid`, `PartiallyValid`, `Overridden` or `TargetNotFound` | `Degraded` |
| `status: False` with any other reason | `Degraded` |
| `status: True` (`Valid`, `Attached`, `Merged`) | `Healthy` |

Across all owned conditions, `Degraded` beats `Progressing`, which beats `Healthy`. The first failing condition supplies the message. An empty message falls back to `<type>: <reason>`. With no owned ancestors at all, the result is `Progressing` ("Waiting for `<Kind>` status"), with one exception below.

**`DirectResponse` exception.** A `DirectResponse` has no `targetRefs`. Routes reference it through an `ExtensionRef` filter, and it gets ancestors only through a route attached to a kgateway Gateway. With no owned ancestors it reads `Healthy`, with "No attachment status reported by kgateway.dev/kgateway". An unused one is config, not pending work, and `Progressing` would stall any sync wave placed before its route. The verdict means only that nothing was reported. A referenced `DirectResponse` still waiting for reconciliation reads the same. An owned ancestor that is pending, stale or missing conditions keeps the normal verdicts.

## The `conditions` script (`Backend`)

| Condition | Verdict |
|---|---|
| `Accepted` or `EndpointsDiscovered` stale | `Progressing` |
| either one `False` | `Degraded` |
| at least one `True`, none `False` | `Healthy` |
| neither present | `Progressing` |

The same precedence applies: `Degraded` beats `Progressing`, which beats `Healthy`. `EndpointsDiscovered` is a runtime condition. A `Backend` can be `Accepted=True` while discovery fails, so the script reads both before deciding.

## Behaviour that depends on the kgateway version

| Situation | v2.4.x | v2.5.x |
|---|---|---|
| Policy whose target doesn't exist | no status → `Progressing` | `TargetNotFound` → `Degraded` |
| Policy whose target exists but isn't attached | no status → `Progressing` | same |
| `DirectResponse` used by an attached route | ancestors → normal verdicts | same |
| `DirectResponse` used by nothing | no status → `Healthy` | same |

Before v2.3.0, kgateway wrote no `DirectResponse` status at all ([kgateway#13647](https://github.com/kgateway-dev/kgateway/pull/13647)), so every `DirectResponse` reads `Healthy` there. Fixtures cover v2.4.5 and v2.5.1; earlier versions are not tested.

## What the checks cannot see

- **What kgateway doesn't report.** A `ListenerPolicy` whose `caCertificateRefs` names a missing ConfigMap is `Accepted=True`, so it reads `Healthy`.
- **Other controllers.** Ancestors from any controller other than `kgateway.dev/kgateway` are ignored, including failures. A build of kgateway that registers another controller name needs `CONTROLLER` changed in `healthchecks/lua/ancestors/health.lua`.
- **A stuck controller.** The checks are stateless, so they can't tell "not reconciled yet" from "never will be". Both read `Progressing`, except for an unused `DirectResponse`, which reads `Healthy`.
- **Traffic.** `Healthy` means kgateway accepted and attached the resource. It doesn't mean requests succeed.
