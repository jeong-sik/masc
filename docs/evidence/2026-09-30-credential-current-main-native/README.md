# Credential feature native checkpoint

The retained raw logs belong to prior source heads, separate from the newly composed full-current-main candidates.

- Prune b695 Test36669352105: completed success, 8/8 native suites, 133 cases. Its 12 prune cases use actual Auth admission barriers and real stored credentials, covering both renewal orders, orphan replacement, preview, UUID/cache, corrupt/foreign owner preservation, dangling raw unlink, partial deletion and failed admission.
- Rotation040 Test36669420029: failed before any suite; the new fixture referenced private Auth.agents_dir. The refreshed fixture derives that directory from public Auth.credential_file. No test-only production API was added.
- Play6714 required CI built merge d80c76d8 and failed in the main-added removed-Keeper test because ~transaction was missing. The refreshed complete main composition wraps that direct read in the same Auth admission. This document reports the observed primary error; a complete required-job log is not retained here.

The four refreshed feature commits preserve the full pinned main c112 tree, release_retired and its feature assertions. Whole API tree identity equals the reviewed local tree for each layer; API/local commit identities differ. Source parsing and independent source review are not native proof. New targeted runs and required checks remain pending. Two root Play dispatch setup mistakes36671779487/36671838501 were cancelled, are not test evidence, and are superseded by source-verified names in36672362813.

Dashboard40190 publishes 11 verified delta blobs over the experimental Item integration parent. Vitest/typecheck/CI-built browser proof remain queued/unmeasured. Browser dependencies/scenario are prepared, but no current screenshot is claimed.

A further read-only audit found file-backed Keeper/bootstrap/login publishers outside Auth admission. Actual source interleavings can delete a freshly published raw token before later credential publication or recreate an orphan raw token after revoke. The next bounded work unit is implementing paired publication and strict current-target authority. That follow-up is not claimed complete or measured here.

No native build ran locally. No installation, live data/config/Goal/credential/controller mutation or production success is claimed.
