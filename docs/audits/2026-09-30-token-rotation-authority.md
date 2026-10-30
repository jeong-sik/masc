# Shared credential rotation authority

## Current contract

`Auth.rotate_shared_tokens` and the selected-name variant return an outer typed error for admission, current-store read, configuration or write-authority refusal before publication. Current canonical names, roles, UUIDs and shared groups are read under one existing Auth credential transaction. The transaction covers every raw sidecar and credential write, excluding current credential publishers, explicit revoke and prune. Startup handles outer refusal separately from individual agent write failures.

The shared private store reader is used by rotation and prune. Decode failure or mismatched canonical identity grants no authority; an actual read error aborts discovery. UUID ownership validation is shared, while prune retains its own deletion manifest. Rotation also checks that payload and named redirect paths are distinct and that distinct selected owners cannot plan the same UUID target, including an absent target. These checks run across all selected groups before any raw sidecar write. Legitimate UUID aliases remain readable.

Each agent write failure retains the error and freshly observed raw-token/credential publication state. A raw token may already be published when credential publication fails, including failures after an atomic rename. Such a result is a failure with partial effects, and cache invalidation still runs. It does not promise rollback or atomic publication of multiple files. Later agents in the admitted batch may continue.

## Source defects repaired

The previous worker grouped credentials before admission and wrote a raw sidecar before acquiring the credential lock. Prune could remove that sidecar before the worker persisted its renewed credential, producing a reported success with no recoverable bearer. A credential renewal or revoke admitted between discovery and save could also be overwritten or resurrected by the stale record. The current worker performs fresh discovery and publication inside the same admission.

Automatic publication also requires ownership of each interpreted UUID write target. A redirect whose record embeds a different owner's UUID, a direct foreign UUID, a traversal id, a self redirect, or two owners planning one absent UUID is refused before sidecar changes.

## Evidence limits

Sixteen feature cases and the existing seven shared-token regression cases are source artifacts for native CI. The new cases cover both admission orders for Admin renewal, prune and revoke; admission/read/config refusal; ambiguous records; raw and second-stage credential failures; UUID aliases; forged/traversal/self/colliding UUID targets. The second-stage write failure fixture uses a readable but non-writable credential directory and requires an unprivileged test process. Tests were not executed locally.

Local evidence is OCaml 5.5.1 parsing, scoped source lint and whitespace checking only. No typecheck, Dune, native test, runtime observation, network or CI result is claimed. The current local parent is `fcaaecff6d051f964e16b65b796ce67140441df7`, the full current-main expiry/prune composition on `c112b2030652a5a25360f5d5322f8dc6da99c598`. The release entry is `changelog.d/40182.md`. Publication and native validation belong to the root agent. The prior rotation native run `36669420029` failed before suites on a private Auth helper reference in the fixture; this source now derives the credential directory from public `Auth.credential_file`. The current composition has not been validated natively.
