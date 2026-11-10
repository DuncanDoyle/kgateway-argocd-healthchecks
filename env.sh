#!/usr/bin/env bash
# Single source of truth for every external version and identifier.
# Swapping the git source (e.g. to an in-cluster Gitea) means changing
# REPO_URL/REPO_REVISION here and nothing else.

# --- git source ArgoCD pulls manifests from -------------------------------
# HTTPS, not SSH: ArgoCD pulls this repo anonymously, and this demo
# deliberately avoids provisioning a deploy-key Secret for it. The SSH
# remote (git@github.com:...) is only used for our own `git push`.
export REPO_URL="https://github.com/DuncanDoyle/kgateway-argocd-healthchecks.git"
export REPO_REVISION="HEAD"

# --- pinned external artifacts --------------------------------------------
# Gateway API CRDs. kgateway 2.5.x is built against v1.7.0; no kgateway
# chart bundles these, so they must be applied first.
export GWAPI_VERSION="v1.7.0"
export GWAPI_MANIFEST="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"

export KGATEWAY_VERSION="v2.5.1"
export KGATEWAY_CRDS_CHART="oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds"
export KGATEWAY_CHART="oci://cr.kgateway.dev/kgateway-dev/charts/kgateway"

export ARGOCD_CHART_REPO="https://argoproj.github.io/argo-helm"
export ARGOCD_CHART_VERSION="10.9.2"

# argo-cd SOURCE revision, not the chart: the commit of argoproj/argo-cd whose
# util/lua test harness CI checks out to run the health checks against the
# committed fixtures. Bump it when rebasing the upstream branch, and re-run the
# harness locally before bumping -- a newer argo-cd can change the harness.
export ARGOCD_SRC_REF="2f3711241f94959924650c9ef554f58a7fbd4d26"

# Pinned by digest: fixtures must be reproducible byte-for-byte.
#
# Documentation-only: nothing sources this variable. manifests/demo/httpbin.yaml
# hardcodes the same image+digest directly on the container spec (Kubernetes
# manifests don't do shell expansion, so it can't reference env.sh at apply
# time). Keeping it here anyway because env.sh is this repo's declared single
# source of truth for versions -- if you bump the digest, update both this
# line and the manifest, and keep them equal.
export HTTPBIN_IMAGE="docker.io/mccutchen/go-httpbin:v2.9.2@sha256:8b27c0fcea0d386992f26d33c0eaadf1709e759f9d3e8b6622d276d10d0569fe"

# --- namespaces ------------------------------------------------------------
export KGATEWAY_NS="kgateway-system"
export ARGOCD_NS="argocd"
export DEMO_NS="httpbin"
export SCENARIOS_NS="scenarios"
