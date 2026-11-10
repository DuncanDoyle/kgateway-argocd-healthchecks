#!/usr/bin/env bash
# Assembles out/resource_customizations/gateway.kgateway.dev/ -- a
# drop-in-ready tree for an argo-cd clone -- from this repo's TRACKED
# content under healthchecks/lua/<Kind>/ (health.lua, health_test.yaml,
# testdata/), and refreshes the 12 LIVE-CAPTURED testdata fixtures from the
# current cluster before assembling.
#
# IMPORTANT -- what this script writes, and what it never touches:
#   - The 12 `extract()` calls below overwrite TRACKED source files under
#     healthchecks/lua/<Kind>/testdata/ directly (not just their copies in
#     out/) -- those tracked files ARE the source of truth for these fixtures,
#     since out/ is gitignored and regenerated. Re-run this script any time the
#     live cluster's status for these resources changes and you want the
#     tracked fixtures to reflect it.
#   - The other 11 of the 23 fixtures are never written by this script:
#       * 7 DERIVED/asserted: Backend/no_status, ListenerPolicy/
#         foreign_controller, TrafficPolicy/{stale,foreign_controller,
#         overridden,overridden_empty_message,partially_valid}.
#       * 1 hand-captured: Backend/stale, a real capture taken mid-probe that
#         cannot be reproduced on demand.
#       * 2 captured on kgateway v2.4.5: {TrafficPolicy,ListenerPolicy}/
#         target_missing_v2_4, kept so the v2.4.x no-status path stays tested.
#       * 1 SYNTHETIC: TrafficPolicy/wrong_shape, a state kgateway never
#         produces.
#     See each file's own header comment for exactly what was substituted. They
#     cannot be reproduced by capturing a live resource, and this script NEVER
#     writes those eleven filenames -- only the 12 named in the `extract` calls
#     below -- so a re-run cannot silently destroy them.
#
# Strips managedFields/uid/resourceVersion/creationTimestamp/annotations --
# noise that upstream's existing fixtures do not carry -- but keeps the
# status subresource completely intact, which is the entire point of the
# fixture.
#
# YAML tooling note: this machine's python3 has no PyYAML module, so the
# original round-trip-through-python approach in the task brief doesn't
# work here. `yq` (mikefarah/yq, Go implementation) is installed, so we
# fetch each resource as JSON via `kubectl -o json` (guaranteed valid JSON,
# no YAML-parsing edge cases) and let `yq -P` convert JSON -> YAML while
# deleting the noisy fields with a single `del()` expression. Output stays
# YAML, as argo-cd's fixtures require.
# SKIP_REFRESH=1 skips the 12 live captures and assembles the tree from the
# fixtures already committed under healthchecks/lua/<Kind>/testdata/. That makes
# this script runnable with no cluster and no kubectl -- which is what lets CI
# verify the Lua and the generated patch. The refresh is the ONLY part that
# needs a cluster; assembly is pure file copying.
set -euo pipefail

cd "$(dirname "$0")/.."
source ./env.sh

SRC="healthchecks/lua"
OUT="out/resource_customizations/gateway.kgateway.dev"
source ./hack/kind-shapes.sh

# extract <namespace> <resource/name> <Kind> <state>
# Captures a live resource and overwrites the TRACKED fixture at
# healthchecks/lua/<Kind>/testdata/<state>.yaml. Only call this for a
# fixture known to be reproducible from a live capture -- see the header
# above; the 12 extract calls below are the complete list.
extract() {
  local ns="$1" res="$2" kind="$3" state="$4"
  local dir="${SRC}/${kind}/testdata"
  mkdir -p "$dir"

  local json target header
  target="${dir}/${state}.yaml"
  json="$(kubectl -n "$ns" get "$res" -o json)"

  # Preserve a hand-written provenance header: the leading run of '#' lines
  # in the existing fixture (if any) is re-emitted ahead of the fresh capture,
  # so annotating a fixture does not make it un-refreshable.
  header=""
  if [ -f "$target" ]; then
    header="$(awk '/^#/ {print; next} {exit}' "$target")"
  fi

  {
    [ -n "$header" ] && printf '%s\n' "$header"
    echo "$json" | yq -P eval '
      del(.metadata.managedFields) |
      del(.metadata.uid) |
      del(.metadata.resourceVersion) |
      del(.metadata.creationTimestamp) |
      del(.metadata.selfLink) |
      del(.metadata.annotations)
    ' -
  } > "${target}.tmp"
  # Skip the overwrite when the capture is semantically identical to the
  # tracked fixture -- "semantically" meaning "as the health check reads it".
  # Two fields change for reasons that have nothing to do with kgateway's
  # behaviour, and would otherwise dirty every tracked fixture whenever the
  # demo cluster is rebuilt:
  #
  #   lastTransitionTime  never read by any health check. Masked outright.
  #   generation /        read ONLY as a comparison -- isStale() asks whether
  #   observedGeneration  condition.observedGeneration equals
  #                       metadata.generation. The absolute numbers carry no
  #                       meaning: a resource applied once (generation 1) and
  #                       the same resource edited six times (generation 7)
  #                       are the same fixture. So the numbers are replaced by
  #                       the only thing the Lua can see -- EQ or NE -- which
  #                       keeps a genuine staleness change (EQ becoming NE)
  #                       detectable while absolute values are ignored.
  #
  # Everything the check actually branches on -- type, status, reason, message,
  # ancestors, controllerName -- is compared verbatim and still forces a write.
  mask_volatile() {
    local gen
    gen="$(yq '.metadata.generation // "none"' "$1")"
    sed -E -e 's/(lastTransitionTime:).*/\1 MASKED/' \
           -e "s/(observedGeneration:) ${gen}\$/\1 EQ/" \
           -e 's/(observedGeneration:) [0-9]+$/\1 NE/' \
           -e 's/(^[[:space:]]*generation:).*/\1 MASKED/' "$1"
  }
  if [ -f "$target" ] && [ "$(mask_volatile "$target")" = "$(mask_volatile "${target}.tmp")" ]; then
    rm -f "${target}.tmp"
  else
    mv "${target}.tmp" "$target"
  fi

  # An ABSENT status is a legitimate state (e.g. dr-unreferenced): an object
  # nothing references may never get a status subresource written at all --
  # not an empty list. Just record it; the set is checked
  # against EXPECT_NO_STATUS once every capture is in, which is a real
  # assertion rather than a line a reader has to count.
  if ! echo "$json" | yq -e '.status' - >/dev/null 2>&1; then
    local name
    name="$(echo "$json" | yq '.metadata.name' -)"
    SAW_NO_STATUS="${SAW_NO_STATUS}${name} "
  fi

  echo "refreshed ${target}"
}

# An absent status subresource is a legitimate captured state, but it is also
# what a broken capture looks like -- a renamed resource, a kubectl that
# returned something unexpected -- and it would silently become a fixture
# asserting nothing. So the set is pinned here as a literal rather than merely
# warned about. Update it in the same commit that adds or removes such a
# resource, which puts the change in front of a reviewer.
EXPECT_NO_STATUS="dr-unreferenced"
SAW_NO_STATUS=""

if [ "${SKIP_REFRESH:-0}" = "1" ]; then
  echo "==> SKIP_REFRESH=1: skipping the 12 live captures; assembling from the committed fixtures"
else
echo "==> Refreshing the 12 live-captured fixtures from the cluster (tracked source, not just out/)"
# NOTE: tp-degraded targets an HTTPRoute in httpbin (TrafficPolicy
# targetRefs have no namespace field, so the policy must be co-located with
# its target route) -- it lives in DEMO_NS, not SCENARIOS_NS. See
# SCENARIOS.md "Where each resource actually lives".
extract "${DEMO_NS}"      backend/httpbin-static        Backend       healthy
extract "${SCENARIOS_NS}" backend/backend-degraded      Backend       degraded
extract "${DEMO_NS}"      trafficpolicy/add-demo-header TrafficPolicy healthy
extract "${DEMO_NS}"      trafficpolicy/tp-degraded     TrafficPolicy degraded
extract "${SCENARIOS_NS}" trafficpolicy/tp-target-missing TrafficPolicy target_missing

# Kinds from the coverage probe (see COVERAGE.md). Each second fixture is named
# after the state actually observed: no_status where the controller writes no
# status at all, degraded where it is genuinely rejected, target_missing where
# the policy targets something that does not exist. lp-degraded-ca is
# deliberately NOT captured: it is Accepted=True despite its dangling reference.
extract "${DEMO_NS}" listenerpolicy/lp-healthy            ListenerPolicy      healthy
extract "${DEMO_NS}" listenerpolicy/lp-degraded-accesslog ListenerPolicy      degraded
extract "${DEMO_NS}" listenerpolicy/lp-target-missing     ListenerPolicy      target_missing
extract "${DEMO_NS}" backendconfigpolicy/bcp-healthy      BackendConfigPolicy healthy
extract "${DEMO_NS}" backendconfigpolicy/bcp-degraded     BackendConfigPolicy degraded
extract "${DEMO_NS}" directresponse/dr-healthy            DirectResponse      healthy
extract "${DEMO_NS}" directresponse/dr-unreferenced       DirectResponse      no_status

  # Compare as sorted sets, so capture order never matters.
  saw="$(printf '%s' "${SAW_NO_STATUS}" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "${saw}" != "${EXPECT_NO_STATUS}" ]; then
    echo "ERROR: resources with no status changed." >&2
    echo "  expected: ${EXPECT_NO_STATUS}" >&2
    echo "  observed: ${saw:-<none>}" >&2
    echo "  A resource that lost its status is a kgateway behaviour change; one that" >&2
    echo "  gained it means a fixture now captures something different. Either way," >&2
    echo "  re-read COVERAGE.md before updating EXPECT_NO_STATUS." >&2
    exit 1
  fi
  # Say so on success too: a silent assertion is indistinguishable from one
  # that never ran. These are expected, not a problem -- hence no
  # "WARNING", which would cry wolf on every single run.
  #
  # stderr, not stdout: check-generated.sh runs this script with >/dev/null to
  # keep its own output quiet, so a check result on stdout would be discarded
  # exactly where it matters most.
  echo "no status on $(printf '%s' "${saw}" | wc -w | tr -d ' ') resources, as expected: ${saw}" >&2
fi

echo
echo "==> Assembling ${OUT} from ${SRC}/ (health.lua, health_test.yaml, testdata/ -- all 23 fixtures: the 12 just-refreshed captures + the 11 tracked fixtures untouched above)"
rm -rf "$OUT"
install_shape() {
  local shape="$1"; shift
  for kind in "$@"; do
    mkdir -p "${OUT}/${kind}"
    cp "healthchecks/lua/${shape}/health.lua" "${OUT}/${kind}/health.lua"
    cp "healthchecks/lua/${kind}/health_test.yaml" "${OUT}/${kind}/health_test.yaml"
    # testdata/ MUST be copied: health_test.yaml's inputPath entries are
    # relative to the kind's directory in the generated tree, so omitting it
    # leaves every test pointing at a file that does not exist.
    cp -R "healthchecks/lua/${kind}/testdata" "${OUT}/${kind}/testdata"
  done
}
install_shape ancestors ${ANCESTORS_KINDS}
install_shape conditions ${CONDITIONS_KINDS}

# Guard against a kind being added to healthchecks/lua/ but forgotten in the
# mapping. Iterate the AUTHORED source directories, not the generated ones:
# a kind missing from the mapping creates no output directory, so checking
# the output cannot see it. argo-cd's harness generates no subtests for a
# directory without health.lua and reports a vacuous pass, so this is the
# only thing standing between a forgotten kind and silent non-coverage.
MAPPED=" ${ANCESTORS_KINDS} ${CONDITIONS_KINDS} "
for src in healthchecks/lua/*/; do
  kind=$(basename "$src")
  # Shape directories hold scripts, not fixtures; skip them.
  [ -f "${src}/health_test.yaml" ] || continue
  case "${MAPPED}" in
    *" ${kind} "*) ;;
    *) echo "ERROR: ${kind} has fixtures but is missing from the shape mapping in hack/kind-shapes.sh" >&2; exit 1 ;;
  esac
  for required in health.lua health_test.yaml testdata; do
    [ -e "${OUT}/${kind}/${required}" ] || { echo "ERROR: ${OUT}/${kind}/${required} missing" >&2; exit 1; }
  done
done

echo
echo "Extraction complete. Review each file before use:"
find "${OUT}" -type f | sort
