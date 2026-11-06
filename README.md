# helm-chart-mirror

Republishes Helm charts from HTTP chart repositories as OCI artifacts on
`ghcr.io/<owner>/charts/<chart>`, for networks that reach ghcr.io but not the
chart repositories.

## Requirements

- A public GitHub repository with Actions enabled. The `sync` workflow runs on
  `ubuntu-24.04`, which ships `helm`, `skopeo`, `jq` and `gh`.
- `sync.sh` by hand: `bash` 4 or later, `helm` 3.8 or later, `skopeo`, `jq`,
  `sha256sum` and an authenticated `gh` CLI.
- Clients: `helm` 3.8 or later, or anything that pulls OCI artifacts.

## Environment

| Req | Name | Default | Purpose |
|---|---|---|---|
| Optional | `CHARTS_FILE` | `charts.txt` | Chart list |
| Optional | `KEEP_VERSIONS` | `5` | Versions kept per chart, newest first. The workflow's `keep` input sets it on a manual run |
| Optional | `DRY_RUN` | `0` | `1` prints what would be pushed and deleted and changes nothing |
| Optional | `ATTEST_SUBJECTS` | `attest-subjects.txt` | Output: verified manifests that have no attestation yet, in `sha256sum` format |
| Required | `GITHUB_REPOSITORY_OWNER` | set by Actions | Owner of the `charts/*` packages |
| Required | `GITHUB_REPOSITORY` | set by Actions | `<owner>/<repo>` the attestations belong to |
| Required | `GH_TOKEN` | set by the workflow | Token with `packages: write`. Also the ghcr.io login |

## Add a chart

1. Find the chart on [Artifact Hub](https://artifacthub.io). Its INSTALL panel
   shows `helm repo add <name> <url>`. Take the URL.
2. Add a line to `charts.txt`: `<url> <chart> [<semver-constraint>]`, for
   example `https://charts.jetstack.io cert-manager` or
   `https://charts.rook.io/release rook-ceph ~1.17` to stay on 1.17.x.
3. Merge. The next run, or **Actions > sync > Run workflow**, pushes it.

A chart that is already published as OCI on a registry the client reaches
(ghcr.io, quay.io) needs no mirror. Pull it from there.

## Usage

The packages are public, so pulling needs no login:

```sh
helm show chart oci://ghcr.io/<owner>/charts/rook-ceph --version v1.18.0
helm install rook-ceph oci://ghcr.io/<owner>/charts/rook-ceph --version v1.18.0
```

To copy a chart into another registry, treat it as an image reference:
`skopeo copy docker://ghcr.io/<owner>/charts/rook-ceph:v1.18.0 docker://<registry>/<path>:v1.18.0`.

## Verify a chart

Three independent checks, none of which trusts this repository:

```sh
ref=ghcr.io/<owner>/charts/cert-manager:v1.21.3
# 1. The chart layer is the upstream archive byte for byte. Compare with the
#    digest field of that version in the upstream index.yaml.
skopeo inspect --raw docker://$ref |
  jq -r '.layers[] | select(.mediaType | endswith("chart.content.v1.tar+gzip")).digest'
curl -fsSL https://charts.jetstack.io/index.yaml |
  yq '.entries.cert-manager[] | select(.version == "v1.21.3") | .digest'
# 2. This repository's workflow published it, signed through Sigstore.
gh attestation verify oci://$ref --repo <owner>/helm-chart-mirror
# 3. Where the publisher signs its charts, their signature was copied with it.
helm pull oci://${ref%:*} --version v1.21.3 --verify --keyring <publisher-key>.gpg
```

Check 1 needs a host that reaches the upstream index. Check 2 needs github.com.

## Trigger a run on demand

A fine-grained token limited to this repository with **Actions: Read and write**
can start the workflow and nothing outside Actions:

```sh
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/<owner>/helm-chart-mirror/actions/workflows/sync.yml/dispatches \
  -d '{"ref":"main"}'
```

`gh workflow run sync.yml --repo <owner>/helm-chart-mirror` does the same.

## Behaviour

- `.github/workflows/sync.yml` runs `sync.sh` every 6 hours and on
  `workflow_dispatch`. Each run first re-enables the workflow, so GitHub's
  60-day inactivity rule for public repositories does not turn the schedule off.
- For each line, `helm search repo --versions` lists the chart's stable
  versions, newest first, filtered by the constraint. Pre-releases are left out.
  The first `KEEP_VERSIONS` are the wanted set.
- A wanted version whose tag is missing from ghcr.io is pulled with
  `helm pull --prov` and pushed with `helm push`, which uploads the
  publisher's `.prov` signature beside the chart when one exists. The archive's
  sha256 must equal the `digest` in the upstream index first, or it is not
  pushed. The archive is pushed unchanged, so the chart layer digest on ghcr.io
  is the upstream digest.
- Every run re-reads each kept version from ghcr.io and fails if its chart
  layer no longer matches the upstream index. A manifest that matches and has
  no attestation yet gets one from `actions/attest-build-provenance`.
- A repository whose index carries no `digest` field is mirrored with a `WARN`
  line, and checks 1 and the pre-push comparison cannot run for it.
- OCI tags cannot hold `+`, so `helm push` tags version `1.0.0+abc` as
  `1.0.0_abc`. Helm maps it back on pull.
- Package versions with no wanted tag are deleted through the GitHub packages
  API. A version that drops out of the newest `KEEP_VERSIONS` upstream goes on
  the next run.
- A failed chart does not stop the others. The run fails at the end and names
  each failure on a `FAIL` line.

## Out of scope

- OCI chart sources. Charts already on an OCI registry are pulled from there.
- Verifying publisher signatures in the mirror. That needs each publisher's
  key, and it is the consumer's trust decision. The signatures are copied so
  the consumer can verify them.
