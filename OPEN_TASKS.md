# Open tasks

Deferred work, in rough priority order. See [ROADMAP.md](ROADMAP.md) for the
programme view and what each phase covers.

**Last updated:** 2026-11-10

## Current approach: ConfigMap first, upstream later

The health checks ship as an `argocd-cm` ConfigMap patch
([docs/INSTALL.md](docs/INSTALL.md)). That works on any ArgoCD version with no
upstream dependency, and it is deliberately the only delivery route for now.

**Contributing these checks to `argoproj/argo-cd` is deferred until the
ConfigMap package has been used in anger.** The reasoning: the Lua is correct
against a test cluster and argo-cd's own harness, but nobody has yet run it
against a real deployment with real resources and real failure modes. Early
users are far better placed to find the gaps than another review pass is, and
anything they turn up is much cheaper to fix in a ConfigMap than in a merged
upstream script that ships on someone else's release cadence.

Upstream is still the destination — it is how everyone gets the checks by
default — just not the next step.

## Before proposing upstream

Only relevant once the ConfigMap package has been validated in real use.

- [ ] **Add a DCO sign-off to the contribution commit.** `argoproj/argo-cd`
      runs a `dco` check on pull requests and will not merge without it:
      `git commit --amend -s`. The sign-off certifies you have the right to
      submit the contribution under the project's licence — see
      [developercertificate.org](https://developercertificate.org/). It is an
      attestation, so it has to be made deliberately rather than added as a
      formatting step.
- [ ] **Replace the PR-link placeholder** in the issue comment draft once a PR
      exists. The draft carries a pre-post checklist.
- [ ] **Re-run the full `./util/lua/` suite** against whatever `upstream/master`
      is at the time. The branch is rebased onto a specific base, and that will
      be stale by then.
- [ ] **Re-read both drafts for accuracy.** They quote fixture counts, a base
      SHA and test results that will all have moved.

## Before the ConfigMap package is handed to anyone

- [x] ~~Verify `setup.sh` on a clean machine.~~ Done 2026-10-12: run against a
      minikube profile created the same morning, so every image was pulled into
      an empty containerd store. The original wording was wrong about scope —
      `setup.sh` does not create the cluster, so the node-image and
      `registry.k8s.io` paths were never its concern. What it does fetch (the
      Gateway API CRD manifest, the kgateway OCI charts, the argo-cd chart) is
      fetched on every run and cannot be masked by a host cache.
- [x] ~~**Follow [docs/INSTALL.md](docs/INSTALL.md) end to end on a cluster you
      did not build.**~~ Done 2026-10-12 on minikube profile `kgw-stock`, with
      ArgoCD v3.5.5 installed from the **upstream manifest** rather than the
      chart — no `setup.sh` values, `controller.resource.health.persist` unset,
      TLS on, and nine pre-existing `argocd-cm` keys. Route A applied from the
      v0.0.1 release asset via `curl`. Result: the five keys merged without
      disturbing the nine; `kgw-scenarios` flipped `Healthy` -> `Degraded` over
      rejected resources *without* enabling persistence; per-resource badges
      rendered correctly once it was enabled; the documented removal loop
      restored `argocd-cm` to its exact original key set. Three doc defects
      found and fixed, listed below. (EKS was considered and rejected: the risk
      lives in the ArgoCD configuration, not the cloud substrate.)
- [x] ~~Bump the pin in `docs/INSTALL.md`.~~ Done 2026-10-12: repinned to
      `8766e51`, the commit carrying both the current patch file and
      `argocd-helm-values.yaml`. **The pinned URLs only resolve once this
      branch is pushed** — until then the guide points at a commit GitHub has
      never seen.
- [x] ~~Run a live `helm upgrade` with `argocd-helm-values.yaml`.~~ Done
      2026-10-12: all five keys removed from `argocd-cm` first, then restored by
      a real `helm upgrade` on chart 10.9.2. Lua byte-identical to
      `healthchecks/lua/<shape>/health.lua` for all five kinds; `server.insecure`,
      `controller.resource.health.persist` and `timeout.reconciliation` all
      survived; badges rendered Healthy/Degraded/Progressing after a hard
      refresh.
- [x] ~~Note the untested paths that document already declares.~~ Resolved
      2026-10-12: both were executed on `kgw-stock`. `persist` unset is the
      stock default and is now the primary tested path; the `curl` download of
      the release asset drove Route A there. Route B's `curl` download and
      ArgoCD 2.x remain the only untested paths, and "What has been tested" now
      says exactly that.

## Documentation gaps

Resolved 2026-10-12 in the README/DEMO readability pass: the three-Application
structure is now introduced before the names are used, `kgw-scenarios` is named
as a prerequisite of the capture scripts, the wait-for-Healthy gate is explicit,
and the sync step no longer assumes a logged-in `argocd` CLI.

- [ ] `docs/evidence/{before,after}.txt` can go stale without anything
      noticing: `hack/check-generated.sh` only diffs `healthchecks/`. If the
      demo or coverage manifests gain or lose a resource, the committed
      evidence keeps showing the old capture until someone re-runs
      `hack/capture-evidence.sh` by hand. Note that `EXPECTED_RESOURCES=14` in
      that script would catch a count change *when run*, but nothing prompts
      the run.
- [x] ~~`docs/INSTALL.md` does not state its `jq` prerequisite.~~ Fixed
      2026-10-12: the comment above the removal loop now names it.
- [x] ~~`docs/INSTALL.md`'s `kubectl rollout restart` line names a
      release-specific StatefulSet.~~ Fixed 2026-10-12. The hardcoded
      `argo-cd-argocd-application-controller` is the argo-helm name and simply
      fails on a stock install, where it is `argocd-application-controller` —
      confirmed live on `kgw-stock`. Replaced with a lookup on
      `app.kubernetes.io/name=argocd-application-controller`, which both shapes
      carry (verified live for stock, and by rendering chart 10.9.2 for helm).
- [ ] `README.md` says `hack/check-generated.sh` needs "the live cluster"; it
      actually needs the cluster **in the states the fixtures expect**.
- [ ] `COVERAGE.md`'s fixtures table says "none reachable" for
      `DirectResponse`'s degraded cell. The evidence supports "none obtained;
      one mechanism tried" — the surrounding prose is correctly hedged, this is
      one cell.

## Tooling

- [x] ~~The pin in `docs/INSTALL.md` can go stale silently.~~ Resolved
      2026-10-12 by releasing: the guide now points at the `v0.0.1` release and
      its attached artefacts instead of a commit SHA. A release tag is created
      after its content exists, so there is no self-reference to work around and
      nothing to remember to bump. (The blob-content check described here is
      still the right answer if a SHA pin is ever reintroduced.)
- [ ] `hack/install-to-argocd-clone.sh` tests `-d "$ARGOCD_DIR/.git"`, which rejects
      a git worktree or submodule checkout where `.git` is a file. Use `-e`.
      Fails safe today. Hit during the v2.5.1 revalidation, which had to
      `rsync` the tree into an argo-cd worktree by hand.
- [ ] `hack/install-to-argocd-clone.sh`'s trailing `git status` can make the script
      exit non-zero after a successful sync, under `set -e`.
- [ ] `hack/install-to-argocd-clone.sh`'s content guard requires only **one**
      `health.lua` in the source, so a half-generated tree could still let
      `rsync --delete` drop the rest from the destination.
- [ ] `hack/capture-evidence.sh`'s "key absent" check treats a `kubectl get`
      failure as absence. Not exploitable — a later step fails under
      `pipefail` — but it is the wrong signal.

## Fixtures and naming

- [ ] Add a `Backend` fixture carrying a condition type kgateway does not own,
      e.g. a third-party `False` condition. The `RECOGNISED` allowlist in
      `conditions/health.lua` is what keeps it out of the verdict, and nothing
      fails today if someone deletes it.

- [ ] `manifests/coverage/listenerpolicy.yaml`'s `lp-degraded-ca` is named and
      commented as a degraded attempt but reports **Healthy**, because kgateway
      accepts a `caCertificateRefs` pointing at a missing ConfigMap. The
      behaviour is real and documented in `COVERAGE.md`; the name misleads in
      the evidence table. Rename it, or change the comment.
- [ ] `docs/evidence/after.txt` ships that `Healthy` row with no in-file note
      explaining it.
- [ ] `COVERAGE.md`'s `bcp-healthy` row still describes a superseded first run
      that targeted the demo's Backend.

## Known kgateway gaps

- [ ] [kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792) —
      `GatewayExtension` declares a status subresource but never populates it.
      Filed 2026-10-06. Until it is implemented, `GatewayExtension` cannot have
      a meaningful health check and stays excluded. Tracked on our side as
      [#1](https://github.com/DuncanDoyle/kgateway-argocd-healthchecks/issues/1), which
      carries the done-when list; a contributor volunteered upstream on
      2026-10-13 proposing the `Backend` conditions pattern, which our existing
      Lua would cover with no new script. That fix is
      [kgateway#14815](https://github.com/kgateway-dev/kgateway/pull/14815),
      waiting on a maintainer to approve its CI workflow runs. Re-checked on
      v2.5.1 (2026-11-10): still no status written. When it lands, drop the
      "writes no status" claim from `ROADMAP.md`, `docs/INSTALL.md`,
      `COVERAGE.md` and the `conditions/health.lua` header in one edit.
