# Dashboard captures

These bundles retain the original observations, logs, screenshots and manifests.
Runnable browser fixtures live under `dashboard/fixtures/`, separate from their
captured output. Run dashboard fixtures with `dashboard/` as the working directory
unless a particular runner explicitly starts its own server from another root.
New captures go under repository `artifacts/dashboard/<bundle>/run-*`.

The recorded source paths and digests in retained manifests describe the original
run. They are not updated to describe relocated or edited reproduction helpers.
A current-source rerun is a new observation, not a replacement for those captures.
See the [storage guide](../../guides/WORKSPACE-STORAGE.md).
