#!/usr/bin/env bash
# Mirror Helm charts from HTTP chart repos to ghcr.io/<owner>/charts/<chart> as OCI.
#
# Reads charts.txt, one "<repo-url> <chart> [<semver-constraint>]" per line. For
# each chart the newest KEEP_VERSIONS stable versions that match the constraint
# are pushed when missing, and package versions outside that set are deleted.
# DRY_RUN=1 prints what would be pushed and deleted and changes nothing.
set -euo pipefail

LIST="${CHARTS_FILE:-charts.txt}"
KEEP="${KEEP_VERSIONS:-5}"
OWNER="${GITHUB_REPOSITORY_OWNER:-}"
DRY="${DRY_RUN:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "KEEP_VERSIONS must be 1 or more: $KEEP"
[ -n "$OWNER" ] || die "GITHUB_REPOSITORY_OWNER must be set"
[ -f "$LIST" ] || die "chart list not found: $LIST"
dest="ghcr.io/${OWNER,,}/charts"

# Organisations and users have separate package endpoints.
if [ "$(gh api "users/$OWNER" --jq .type)" = Organization ]; then
  pkg_api="orgs/$OWNER/packages/container"
else
  pkg_api="user/packages/container"
fi

if [ "$DRY" != 1 ]; then
  printf '%s' "$GH_TOKEN" | helm registry login ghcr.io -u "$OWNER" --password-stdin >/dev/null
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HELM_REPOSITORY_CONFIG="$work/repositories.yaml" HELM_REPOSITORY_CACHE="$work/cache"

failed=0
while read -r url chart constraint; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  [[ "$url" =~ ^https?:// ]] || die "repo URL must be http(s): $url"
  [[ "$chart" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "unexpected chart name: $chart"

  # One alias per repo URL, so charts from the same repo share one index download.
  alias="r$(printf '%s' "$url" | sha256sum | cut -c1-12)"
  if ! helm repo list -o json 2>/dev/null | jq -e --arg a "$alias" 'any(.[]; .name == $a)' >/dev/null; then
    helm repo add "$alias" "$url" >/dev/null || { echo "FAIL $url: helm repo add"; failed=1; continue; }
  fi

  # helm search lists newest first and leaves out pre-releases. Some repos
  # publish one release as both 1.2.3 and v1.2.3: both are kept, and count as
  # one of the KEEP_VERSIONS releases.
  args=(search repo "$alias/$chart" --versions -o json)
  [ -n "${constraint:-}" ] && args+=(--version "$constraint")
  mapfile -t want < <(helm "${args[@]}" |
    jq -r --arg n "$alias/$chart" '.[] | select(.name == $n) | .version' |
    awk -v n="$KEEP" '{ k = $0; sub(/^v/, "", k) } !(k in s) { s[k]; c++ } c <= n')
  [ "${#want[@]}" -gt 0 ] || { echo "FAIL $chart: no versions in $url"; failed=1; continue; }

  # OCI tags cannot hold "+", so helm push writes it as "_".
  have=$(skopeo list-tags "docker://$dest/$chart" 2>/dev/null | jq -r '.Tags[]' || true)
  for v in "${want[@]}"; do
    grep -qxF "${v//+/_}" <<<"$have" && continue
    echo "push $chart $v"
    [ "$DRY" = 1 ] && continue
    if ! { helm pull "$alias/$chart" --version "$v" -d "$work" >/dev/null &&
      helm push "$work/$chart-$v.tgz" "oci://$dest"; }; then
      echo "FAIL $chart $v: pull or push"; failed=1
    fi
  done

  # Delete package versions none of whose tags is wanted, untagged ones included.
  # A package that does not exist yet returns 404 and is skipped.
  keep_tags=$(printf '%s\n' "${want[@]//+/_}" | jq -Rsc 'split("\n") | map(select(. != ""))')
  versions=$(gh api --paginate "$pkg_api/charts%2F$chart/versions" 2>/dev/null) || versions='[]'
  jq -r --argjson k "$keep_tags" \
      '.[] | select(any(.metadata.container.tags[]; IN($k[])) | not)
           | "\(.id) \(.metadata.container.tags | join(","))"' <<<"$versions" |
    while read -r id tags; do
      echo "delete $chart ${tags:-<untagged>}"
      [ "$DRY" = 1 ] && continue
      gh api -X DELETE "$pkg_api/charts%2F$chart/versions/$id" >/dev/null ||
        echo "FAIL $chart: delete version $id"
    done
done < "$LIST"

[ "$failed" = 0 ] || die "one or more charts failed, see the FAIL lines"
echo "done"
