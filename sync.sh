#!/usr/bin/env bash
# Mirror Helm charts from HTTP chart repos, and images from registries a client
# cannot reach, to ghcr.io/<owner>/<source path>. The source path stays in the
# name so anyone reading a reference can tell where it came from.
#
# Reads charts.txt, one "<repo-url> <path> [<semver-constraint>]" per line, where
# <path> is the upstream project path ending in the chart name. For
# each chart the newest KEEP_VERSIONS stable versions that match the constraint
# are pushed when missing, and package versions outside that set are deleted.
# Each download is checked against the digest in the upstream index before the
# push, every kept version on ghcr.io is re-checked on every run, and a
# publisher's .prov signature is copied when one exists. Verified manifests
# without a GitHub attestation are listed in ATTEST_SUBJECTS for the workflow.
# Reads images.txt, one "<registry>/<path>:<tag>" per line. Each image is copied
# with every architecture and its digest unchanged to ghcr.io/<owner>/<path>,
# and the copy is checked against the source digest on every run.
# DRY_RUN=1 prints what would be pushed and deleted and changes nothing.
set -euo pipefail

LIST="${CHARTS_FILE:-charts.txt}"
IMAGES="${IMAGES_FILE:-images.txt}"
KEEP="${KEEP_VERSIONS:-5}"
OWNER="${GITHUB_REPOSITORY_OWNER:-}"
REPO="${GITHUB_REPOSITORY:-}"
SUBJECTS="${ATTEST_SUBJECTS:-attest-subjects.txt}"
DRY="${DRY_RUN:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "KEEP_VERSIONS must be 1 or more: $KEEP"
[ -n "$OWNER" ] || die "GITHUB_REPOSITORY_OWNER must be set"
[ -n "$REPO" ] || die "GITHUB_REPOSITORY must be set"
: > "$SUBJECTS"
[ -f "$LIST" ] || die "chart list not found: $LIST"
base="ghcr.io/${OWNER,,}"

# Organisations and users have separate package endpoints.
if [ "$(gh api "users/$OWNER" --jq .type)" = Organization ]; then
  pkg_api="orgs/$OWNER/packages/container"
else
  pkg_api="user/packages/container"
fi

if [ "$DRY" != 1 ]; then
  printf '%s' "$GH_TOKEN" | helm registry login ghcr.io -u "$OWNER" --password-stdin >/dev/null
  printf '%s' "$GH_TOKEN" | skopeo login ghcr.io -u "$OWNER" --password-stdin >/dev/null
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HELM_REPOSITORY_CONFIG="$work/repositories.yaml" HELM_REPOSITORY_CACHE="$work/cache"

failed=0
while read -r url path constraint; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  [[ "$url" =~ ^https?:// ]] || die "repo URL must be http(s): $url"
  [[ "$path" =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || die "path must be <project>/.../<chart>: $path"
  chart=${path##*/} dest="$base/${path%/*}" pkg=${path//\//%2F}

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
  index="$HELM_REPOSITORY_CACHE/$alias-index.yaml"
  for v in "${want[@]}"; do
    tag=${v//+/_}
    # The sha256 of the chart archive as the upstream index publishes it. The
    # field is optional in a chart repository, so it can be empty.
    up=$(yq -r ".entries[\"$chart\"][] | select(.version == \"$v\") | .digest // \"\"" "$index")
    [ -n "$up" ] || echo "WARN $chart $v: upstream index has no digest, the copy cannot be checked against it"

    if ! grep -qxF "$tag" <<<"$have"; then
      echo "push $chart $v"
      [ "$DRY" = 1 ] && continue
      tgz="$work/$chart-$v.tgz"
      # --prov also fetches the publisher's signature, which helm push uploads
      # next to the chart. Most repositories publish none.
      helm pull "$alias/$chart" --version "$v" -d "$work" --prov >/dev/null 2>&1 ||
        helm pull "$alias/$chart" --version "$v" -d "$work" >/dev/null ||
        { echo "FAIL $chart $v: pull"; failed=1; continue; }
      got=$(sha256sum "$tgz" | cut -d' ' -f1)
      if [ -n "$up" ] && [ "$got" != "$up" ]; then
        echo "FAIL $chart $v: download $got differs from upstream index $up, not pushed"; failed=1; continue
      fi
      helm push "$tgz" "oci://$dest" >/dev/null || { echo "FAIL $chart $v: push"; failed=1; continue; }
    fi
    [ "$DRY" = 1 ] && continue

    # Every run re-checks every kept version: the chart layer on ghcr.io must be
    # the upstream archive byte for byte. A match is attested once.
    manifest=$(skopeo inspect --raw "docker://$dest/$chart:$tag") ||
      { echo "FAIL $chart $v: cannot read the ghcr.io manifest"; failed=1; continue; }
    layer=$(jq -r '.layers[] | select(.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest' <<<"$manifest")
    prov=$(jq -r 'any(.layers[]; .mediaType == "application/vnd.cncf.helm.chart.provenance.v1.prov")' <<<"$manifest")
    if [ -n "$up" ] && [ "$layer" != "sha256:$up" ]; then
      echo "FAIL $chart $v: ghcr.io layer $layer differs from upstream index sha256:$up"; failed=1; continue
    fi
    echo "ok $chart $v layer=$layer signed=$prov"
    mdigest=$(printf '%s' "$manifest" | sha256sum | cut -d' ' -f1)
    gh api "repos/$REPO/attestations/sha256:$mdigest" >/dev/null 2>&1 ||
      printf '%s  %s\n' "$mdigest" "$dest/$chart:$tag" >> "$SUBJECTS"
  done

  # Delete package versions none of whose tags is wanted, untagged ones included.
  # A package that does not exist yet returns 404 and is skipped.
  keep_tags=$(printf '%s\n' "${want[@]//+/_}" | jq -Rsc 'split("\n") | map(select(. != ""))')
  versions=$(gh api --paginate "$pkg_api/$pkg/versions" 2>/dev/null) || versions='[]'
  jq -r --argjson k "$keep_tags" \
      '.[] | select(any(.metadata.container.tags[]; IN($k[])) | not)
           | "\(.id) \(.metadata.container.tags | join(","))"' <<<"$versions" |
    while read -r id tags; do
      echo "delete $chart ${tags:-<untagged>}"
      [ "$DRY" = 1 ] && continue
      gh api -X DELETE "$pkg_api/$pkg/versions/$id" >/dev/null ||
        echo "FAIL $chart: delete version $id"
    done
done < "$LIST"

# Images: copied by tag, never pruned. A removed line leaves its package as is.
if [ -f "$IMAGES" ]; then
  while read -r src; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    [[ "$src" =~ ^[a-z0-9.-]+\.[a-z]+(:[0-9]+)?/[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] ||
      die "image must be <registry>/<path>:<tag>: $src"
    path=${src#*/} out="$base/$path"
    up=$(skopeo inspect --raw "docker://$src" | sha256sum | cut -d' ' -f1) ||
      { echo "FAIL $src: cannot read the source manifest"; failed=1; continue; }
    have=$(skopeo inspect --raw "docker://$out" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
    if [ "$have" != "$up" ]; then
      echo "push $src"
      [ "$DRY" = 1 ] && continue
      skopeo copy --all --preserve-digests --retry-times 3 "docker://$src" "docker://$out" >/dev/null ||
        { echo "FAIL $src: copy"; failed=1; continue; }
      have=$(skopeo inspect --raw "docker://$out" | sha256sum | cut -d' ' -f1)
      [ "$have" = "$up" ] || { echo "FAIL $src: ghcr.io digest $have differs from source $up"; failed=1; continue; }
    fi
    [ "$DRY" = 1 ] && continue
    echo "ok $src digest=sha256:$up"
    gh api "repos/$REPO/attestations/sha256:$up" >/dev/null 2>&1 ||
      printf '%s  %s\n' "$up" "$out" >> "$SUBJECTS"
  done < "$IMAGES"
fi

# The workflow attests the listed manifests when there are any.
echo "attest=$([ -s "$SUBJECTS" ] && echo true || echo false)" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$(wc -l < "$SUBJECTS" | tr -d ' ') manifest(s) to attest"

[ "$failed" = 0 ] || die "one or more charts or images failed, see the FAIL lines"
echo "done"
