# Dashboard build artifacts

The `Dashboard artifact` workflow builds the revision selected by dispatch on
GitHub's runner. It exercises the production-bundle test, runs `pnpm build`, and
uploads `masc-dashboard-<full-source-commit>` containing:

- `masc-dashboard-<full-source-commit>.tar.gz`, with `dashboard/index.html`,
  `dashboard/assets/`, and `dashboard/.build-stamp`.
- `dashboard-build-receipt.json`, with the source commit/tree, workflow run,
  build time, lockfile digest, tool versions, archive digest, and index digest.
- `SHA256SUMS`, for checking the archive after downloading it.

Vite emits the stamp during bundle generation. The tar archive preserves its
mtime; extraction must not replace that time with the download/deployment time.
A stamp says a bundle was built. The receipt and archive digest identify which
source and bytes were built. Neither alone proves the live server uses them.

The existing `build-dashboard-if-needed.sh` helper can refresh a stamp without
rebuilding when it judges sources unchanged and the server binary is newer.
This workflow does not use that shortcut: it always runs a real Vite build.
The stamp is a successful-bundle freshness indicator; source provenance belongs
to the build receipt, not the stamp.

## Build and stage

After the workflow is present on the default branch, dispatch the desired ref:

```sh
gh workflow run dashboard-artifact.yml --repo jeong-sik/masc --ref <source-ref>
```

Record the run ID and full `headSha` from that run. At the completion boundary,
check its conclusion, then download to a new staging directory:

```sh
gh run download <run-id> --repo jeong-sik/masc \
  --name masc-dashboard-<full-source-commit> --dir <staging-directory>
```

In that staging directory, run `shasum -a 256 -c SHA256SUMS` and compare the
receipt's `source_commit` to the run's `headSha` and the intended revision. Extract
the verified archive into a separate staging assets directory using `tar -xzf`.
The archive creates its `dashboard/` child, including the hidden stamp.

This workflow stages an artifact; it does not deploy. Before installation, read
`/health?full=1` for `dashboard_surface.dashboard_asset_root` and
`dashboard_surface.dashboard_manifest_root`. An unbound runtime serves the
reported assets directory. A runtime with a manifest serves immutable bound
assets and requires a new launch binding; overwriting the checkout is not a
replacement for that binding. Coordinate replacement of the complete assets
directory with the deployment owner and preserve the previous bundle for rollback.

After installation, read `/health?full=1` again, verify the served index digest
against the receipt, and exercise the dashboard in a browser. If the server
reports stale assets, inspect the intended server/bundle revisions; do not touch
the stamp to claim a newer build.
