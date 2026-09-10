# Applied edits retain their artifact result

Successful Edit stored its before/after files but returned their typed handles
without attaching the result manifest required by the model bridge. The bridge
then replaced the already-applied result with a generic artifact-storage error.

The filesystem producer now attaches the durable manifest before returning its
successful result. This post-commit work remains cancellation-protected, and the
original file-change evidence and both snapshot references are retained.

If manifest persistence actually fails, the producer returns a typed failure
with `Proven_post_effect`. That existing effect disposition now travels in
`Tool_result.failure_payload` through the Keeper handler into the model bridge.
The bridge returns an error with an explicit applied-effect warning and the
original artifact retrieval handles, without sending it through the failed
manifest projector again. The terminal callback retains the proven applied
failure so an official-client loop does not treat it as an unperformed edit.
Unspecified failure effects remain `Effect_outcome_unknown`.

The full model-tool test uses the real filesystem producer, Keeper handler and
bridge. It verifies a committed edit, durable manifest and exact snapshot bytes.
A second case blocks the real artifact directory only after snapshot writes,
then verifies that the edit stays applied, the response stays an error, the
terminal boundary knows the effect happened, and both references remain usable
when storage access is restored. No local build was run; CI remains required.
