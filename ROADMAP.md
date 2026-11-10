# ArgoCD health checks for kgateway — roadmap

Programme-level view of the work tracked by
[kgateway-dev/kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).
Each phase gets its own design spec and implementation plan under
[`docs/superpowers/`](docs/superpowers/); this page says what ships, in what
order, and why some kinds are excluded. Further phases may follow once these
complete; they are not described here.

**Last updated:** 2026-11-10

## The problem

ArgoCD has no built-in health checks for kgateway's CRDs, so resources managed
by an ArgoCD Application show `(none)` for health even when the controller has
written a clear status. Worse, an Application full of broken kgateway resources
reports **Healthy**, because ArgoCD has no opinion about resources it cannot
assess. Standard `gateway.networking.k8s.io` resources do have checks; the
`gateway.kgateway.dev` ones do not.

**Open work is tracked in [OPEN_TASKS.md](OPEN_TASKS.md).**

## Delivery model

Two vehicles for the same Lua, and the order matters:

1. **`argocd-cm` ConfigMap — ships first.** Works on any ArgoCD version with no
   upstream dependency, which makes it both the development loop (edit, apply,
   watch the badge change in ~10s) and the first thing users get.
2. **Bundled upstream in `argoproj/argo-cd` — deferred.** Not the next step: the ConfigMap package is validated in real use first, since early users find gaps a review pass cannot, and a fix is far cheaper in a ConfigMap than in a merged upstream script. See [OPEN_TASKS.md](OPEN_TASKS.md).
   It remains the destination — it is how everyone gets the checks by default,
   on ArgoCD's release cadence — just not yet.

`argocd-cm` entries **override** bundled checks (`util/lua/lua.go`,
`GetHealthScript`: configmap exact → configmap wildcard → embedded exact →
embedded wildcard). So the ConfigMap is not merely a stopgap — it stays valid
after the upstream PR merges, and remains the escape hatch for anyone who needs
different semantics. The docs must say when it is safe to remove.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | `Backend`, `TrafficPolicy` | **Complete.** Cluster-captured fixtures, passing argo-cd's own harness, proven on a live cluster |
| 2 | `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse` | **Implemented.** [Design](docs/superpowers/specs/2026-10-06-phase2-design.md), [plan](docs/superpowers/plans/2026-10-06-phase-a2.md); 23 fixtures across five kinds pass the upstream harness |

Phase 2 completes coverage of every `gateway.kgateway.dev` kind that has a
status to check — five of seven on kgateway v2.5.x (five of eight on v2.4.x,
which still ships `HTTPListenerPolicy`) — and closes #13871 with documented
exclusions. The checks then ship as a documented ConfigMap package, followed by
the upstream argo-cd PR.

### Currently supported

```
resource.customizations.health.gateway.kgateway.dev_Backend
resource.customizations.health.gateway.kgateway.dev_TrafficPolicy
resource.customizations.health.gateway.kgateway.dev_ListenerPolicy
resource.customizations.health.gateway.kgateway.dev_BackendConfigPolicy
resource.customizations.health.gateway.kgateway.dev_DirectResponse
```

### Excluded, with reasons

| Kind | Why |
|---|---|
| `GatewayParameters` | No status implemented — the CRD schema says so outright. Any check would be a constant. Revisit if kgateway implements status. |
| `HTTPListenerPolicy` | Deprecated in 2.4.x in favour of `ListenerPolicy.spec.httpSettings`, and removed in 2.5.x. |
| `GatewayExtension` | Writes no status at all — verified on live v2.4.5 and v2.5.1 clusters, not inferred: a valid and an invalid instance both produced no `status` block while the controller logged successful reconciliation. The API declares the status type and the CRD carries `/status` RBAC, but nothing populates it. Filed as [kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792); fix proposed in [kgateway#14815](https://github.com/kgateway-dev/kgateway/pull/14815). |

## Phase 2 design decisions

Brings `gateway.kgateway.dev` coverage to five kinds and **closes #13871**.

Two byte-identical Lua scripts (one per status shape) use `obj.kind` for
messages, copied per kind with a drift test — argo-cd's Lua VM has no module
system, so this is the only way to avoid hand-maintained copies. A third ArgoCD
Application, `kgw-coverage`, holds the new kinds so the demo narrative stays
minimal. Phase 1's two scripts were refactored onto the shared form; that change
is behaviour-preserving, so the phase 1 fixtures were its regression test.

**Ships:** the ConfigMap package, then the upstream PR.

## Before release

Release gates, carried from phase 1 as known gaps rather than discovered late:

- [x] ~~Verify `setup.sh` on a clean machine.~~ Done 2026-10-12: run against a
      minikube profile created the same morning, so every image was pulled into
      an empty containerd store. The original wording was wrong about scope —
      `setup.sh` does not create the cluster, so the node-image and
      `registry.k8s.io` paths were never its concern. What it does fetch (the
      Gateway API CRD manifest, the kgateway OCI charts, the argo-cd chart) is
      fetched on every run and cannot be masked by a host cache.
- [x] Regenerate `healthchecks/argocd-cm-patch.yaml` for all five kinds.
- [x] Refresh `docs/evidence/` so the before/after capture covers five kinds.
- [x] Write the package documentation ([docs/INSTALL.md](docs/INSTALL.md)).

## Documentation deliverables

| Deliverable | Audience | State |
|---|---|---|
| Package docs — install, what each status means, how to remove once upstream ships | kgateway users | written ([docs/INSTALL.md](docs/INSTALL.md)) |
| Upstream PR body + `#13871` closing comment | argo-cd maintainers, kgateway community | with the PR |
| Entry in the kgateway docs | kgateway users | after the upstream PR — owner TBD |

The repo's other docs (`README.md`, `DEMO.md`, `SCENARIOS.md`) are written for
people reproducing the fixtures, not for consumers of the checks.

## Method

Worth stating because it constrains scheduling, and because departing from it
caused every significant defect found so far:

- **Probe first.** Scenario behaviour is predicted from source, then verified on
  a live cluster before fixtures are built. Phase 1's probe caught two API
  errors that would otherwise have shipped.
- **Capture, don't author.** Fixtures are `kubectl get -o yaml` from a real
  cluster. Where a state cannot be produced, say so in the PR rather than
  fabricating it. Derived fixtures carry a header disclosing exactly what was
  substituted.
- **Verify shipped CRDs, not Go types.** The inventory moves between lines:
  kgateway v2.4.5 ships 8 CRDs, v2.5.1 ships 7.

## Open decisions

- Exact timing of the upstream PR relative to the ConfigMap release — the PR is
  held at a local commit until the phase 2 work is folded in.
