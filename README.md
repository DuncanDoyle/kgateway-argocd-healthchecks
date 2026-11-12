# ArgoCD health checks for kgateway

ArgoCD ships no health checks for `gateway.kgateway.dev/*` resources, so they show `(none)` in the resource tree — an Application can be fully synced while the policies inside it are rejected, and the UI says nothing. This repo is the source for those health checks. It also deploys a real kgateway demo through ArgoCD, because that demo is how the checks are proven against real status rather than hand-written fixtures.

To install them, you need nothing from this repo but one generated file — see [docs/INSTALL.md](docs/INSTALL.md).

Tracks [kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).

## Start here

| If you want to… | Go to |
|---|---|
| **Use the health checks** in your own ArgoCD | [docs/INSTALL.md](docs/INSTALL.md) — a ConfigMap patch, no dependency on this repo |
| **Understand how a verdict is reached**, kind by kind | [docs/HEALTH-MODEL.md](docs/HEALTH-MODEL.md) — the in-depth appendix |
| **Run the demo** | [DEMO.md](DEMO.md) — after `./setup.sh` below |
| **Work on the checks**, regenerate fixtures, or run the test harness | the rest of this page |
| See the phase plan and what is deliberately out of scope | [ROADMAP.md](ROADMAP.md) |
| See what is still open | [OPEN_TASKS.md](OPEN_TASKS.md) |

## How the repo is laid out

| Path | What is in it |
|---|---|
| `healthchecks/lua/<Kind>/` | **The product.** One `health.lua` per CRD kind, its `health_test.yaml`, and `testdata/` fixtures. Tracked, reviewed, and the source of everything else. |
| `healthchecks/argocd-cm-patch.yaml` | Generated — a `kubectl patch` of `argocd-cm`. |
| `healthchecks/argocd-helm-values.yaml` | Generated — the same five scripts as argo-helm values, for anyone whose `argocd-cm` is managed declaratively. |
| `manifests/` | Kubernetes manifests, in three sets: `demo/`, `coverage/`, `scenarios/`. [DEMO.md](DEMO.md) explains what each set is for. |
| `argocd/` | One ArgoCD Application per manifest set. |
| `hack/` | Scripts to generate the five per-kind copies, capture fixtures from a live cluster, and check nothing has drifted. [hack/README.md](hack/README.md) explains each one. |
| `out/` | Gitignored scratch. A drop-in-ready `resource_customizations/` tree assembled for an argo-cd clone. |
| `env.sh` | Every external version and identifier, in one place. |
| `.github/workflows/` | CI: the generated-file check and the argo-cd Lua harness, both cluster-free. |
| `docs/` | [INSTALL.md](docs/INSTALL.md), its in-depth appendix [HEALTH-MODEL.md](docs/HEALTH-MODEL.md), the `evidence/` transcripts behind its claims, and `superpowers/` — the canonical design spec and phase plans. |

**Where a document lives tells you who it is for.** `docs/INSTALL.md` is the only one written for someone who will never clone this repo: they want health checks in their own ArgoCD and nothing else. Everything in the root assumes you have the repo checked out and are running or working on the demo — [DEMO.md](DEMO.md) (running it), [COVERAGE.md](COVERAGE.md) (what status each coverage resource actually produced), [SCENARIOS.md](SCENARIOS.md) (the deliberately broken resources), [ROADMAP.md](ROADMAP.md) and [OPEN_TASKS.md](OPEN_TASKS.md). `hack/README.md` sits with the scripts it describes.

## Requirements

- A Kubernetes cluster — you create it; `setup.sh` does not. See [Quick start](#quick-start).
- `kubectl`, `helm`, `curl`, `jq`
- Only to run the upstream test harness: Go, and a clone of `argoproj/argo-cd`

## Quick start

`setup.sh` installs the Gateway API CRDs, kgateway and ArgoCD into whatever cluster your current kubectl context points at. **It does not create the cluster.**

This is the configuration the demo is developed and verified against:

```bash
minikube start -p kgw-argocd --driver=vfkit --container-runtime=containerd \
  --kubernetes-version=v1.34.7 --cpus=4 --memory=16384
kubectl config use-context kgw-argocd

./setup.sh
```

`--driver=vfkit` is macOS on Apple silicon; use `docker`, `kvm2` or whatever suits your machine. Nothing in this repo is minikube-specific — any cluster works. The Kubernetes version is not pinned by anything here, but `GWAPI_VERSION` in [`env.sh`](env.sh) is pinned to the kgateway line, so keep those two in step if you change either.

The 16 GB is what this has been run with, not a measured floor: kgateway, ArgoCD and the demo workload all share it. A smaller allocation tends to fail as pods stuck Pending rather than as an obvious out-of-memory error.

Then follow [DEMO.md](DEMO.md).

Teardown is `./teardown.sh`, which removes everything `setup.sh` installed but leaves ArgoCD's own CRDs — the chart marks them `helm.sh/resource-policy: keep`. To discard the whole cluster instead: `minikube delete -p kgw-argocd`.

## Verifying the health checks

The real gate is argo-cd's own test harness, not the badges in the UI.

29 fixtures are tracked under `healthchecks/lua/<Kind>/testdata/`, across five kinds: `Backend`, `TrafficPolicy`, `ListenerPolicy`, `BackendConfigPolicy` and `DirectResponse`. 15 are captured live (2 of them on kgateway v2.4.5), 13 are derived from a capture, and 1 is synthetic — each file's header comment says which, as does the header of `hack/extract-testdata.sh`.

```bash
./hack/extract-testdata.sh      # refresh fixtures from the cluster, assemble out/
./hack/install-to-argocd-clone.sh     # mirror that tree into your argo-cd clone
cd <path-to-argo-cd-clone>
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Verified against argo-cd `2f3711241` (the base of the upstream branch): 29 passing fixtures.

[hack/README.md](hack/README.md) explains what each script does, how the three verification layers differ, and which one will blank every badge in your UI for a minute.

**`extract-testdata.sh` needs all three Applications deployed, not just the demo.** It refreshes 12 fixtures from the live cluster and 7 of those come from the coverage resources, so it fails on the first resource it cannot find. Follow [DEMO.md](DEMO.md) through step 2, which also explains why the coverage Application has to be applied *after* `kgw-demo` has synced.

`install-to-argocd-clone.sh` reads the clone location from `ARGOCD_DIR` (it sets a default; override it for yours). It refuses an empty source and syncs only the `resource_customizations/gateway.kgateway.dev` directory, so uncommitted work elsewhere in your clone is never touched. Prefer it over `cp -r`, which leaves stale files behind when a fixture is removed.

### Why health does not show up in `kubectl`

`setup.sh` sets `controller.resource.health.persist: "true"` on the ArgoCD Helm release. Without it, ArgoCD's default (`resourceHealthSource: appTree`) never writes per-resource health onto `Application.status.resources[]`. The UI still shows the badges correctly, but `kubectl get application … -o jsonpath='…health.status…'` returns nothing **whether or not the checks work** — so every CLI-based verification of this demo silently passes.

Pointing this demo at an ArgoCD install that predates the setting? Add it and re-run `helm upgrade`. The application-controller restarts by itself, because the chart checksums `argocd-cmd-params-cm` into its pod template.

### Checking the generated files have not drifted

`healthchecks/` holds generated artefacts — the captured fixtures and the `argocd-cm` patch. This re-runs both generators and fails on any difference:

```bash
./hack/check-generated.sh              # needs the live cluster
SKIP_REFRESH=1 ./hack/check-generated.sh   # no cluster; what CI runs
```

It needs the live cluster **in the states the fixtures expect** (all three Applications synced), and a clean `healthchecks/` tree to start from, so uncommitted edits are not mistaken for drift. Re-captures differing only in `lastTransitionTime` do not count.

Phase 1 shipped an `argocd-cm` patch that silently disagreed with its own scripts for weeks, because nothing compared them. Hence this script.

### Regenerating the before/after evidence

```bash
./hack/capture-evidence.sh
```

Removes every health key from `argocd-cm`, captures `docs/evidence/before.txt` (asserting every health status is empty), applies the patch, then captures `after.txt` (asserting every status is non-empty). It hard-refreshes the Applications each time, because they cache per-resource health and ignore an `argocd-cm` change until refreshed — a plain `sleep` yields plausible but stale output.

### A convention worth knowing before you add assertions

**Every assertion over a collection must first assert the collection is non-empty, with the expected count as a literal.**

A predicate quantified over an empty set is vacuously true, so "all statuses are empty" and "all fixtures pass" both succeed having checked nothing. This repo has been bitten by it repeatedly, including a test harness that reported `ok` while running zero tests. Writing the count as a literal means that when the set grows or shrinks, the number changes in the same commit — and a reviewer sees it.

## Versions

All pins live in [`env.sh`](env.sh), which is the authoritative list.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
