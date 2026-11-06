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
| Required | `GITHUB_REPOSITORY_OWNER` | set by Actions | Owner of the `charts/*` packages |
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

## Behaviour

- `.github/workflows/sync.yml` runs `sync.sh` every 6 hours and on
  `workflow_dispatch`. Each run first re-enables the workflow, so GitHub's
  60-day inactivity rule for public repositories does not turn the schedule off.
- For each line, `helm search repo --versions` lists the chart's stable
  versions, newest first, filtered by the constraint. Pre-releases are left out.
  The first `KEEP_VERSIONS` are the wanted set.
- A wanted version whose tag is missing from ghcr.io is pulled with
  `helm pull` and pushed with `helm push`. The chart archive is pushed
  unchanged, so its digest is stable across runs.
- OCI tags cannot hold `+`, so `helm push` tags version `1.0.0+abc` as
  `1.0.0_abc`. Helm maps it back on pull.
- Package versions with no wanted tag are deleted through the GitHub packages
  API. A version that drops out of the newest `KEEP_VERSIONS` upstream goes on
  the next run.
- A failed chart does not stop the others. The run fails at the end and names
  each failure on a `FAIL` line.

## Out of scope

- OCI chart sources. Charts already on an OCI registry are pulled from there.
- Signing and provenance. `helm pull --verify` needs the publisher's key, and
  few chart repositories publish one.
