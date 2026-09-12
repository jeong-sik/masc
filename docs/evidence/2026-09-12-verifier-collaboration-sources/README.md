# Standalone verification of collaboration sources

Task004's verdict could not independently inspect referenced peer discussion or Fusion results. The read-only verifier surface now resolves original Board posts/comments and full Fusion source evidence by their existing canonical IDs. It does not infer existence from a textual reference or add write, execution, voting, deliberation or adoption tools.

Task review uses the actual submitting producer: it may read shared peer Board discussions and its own Fusion sources. Goal review uses shared records in the active workspace. Direct posts are available only to their author through Task review; immutable target readership is not available here, so foreign Direct reads remain an explicit unsupported authority rather than being granted from mutable mentions. The active Board workspace must match the review config. This is a limited access policy, not proof of full Direct-conversation verification support.

Original post/comment IDs, authors, body and metadata are preserved. Board comment pagination states totals and the next offset. Fusion source origin and run ID are checked, full panel/judge/source context is returned with the same evidence hash used by separately recorded Keeper decisions. Reads do not adopt the judge's advice.

Review fixed an error-classification defect in the initial implementation: request/missing-source rejection, denied access and actual storage failure now remain different typed failures. The dispatch tests exercise shared peer comments, Direct limits, source ownership, wrong origin, missing records, corrupt decision storage, workspace mismatch and absence of mutation tools. Parse-only OCaml and diff checks passed locally. Native execution requires CI; no local MASC build or deployed success is claimed.

Stacked on PR35511's canonical Fusion source retrieval. The MP4/PDF inspector changes are separate dependencies and are not included in this component branch.

CI follow-up: the original feature test failed to type-check because its post helper inferred a sub-board record from the shared `id` label. The helper now declares `Board.post`. Optional comment pagination now defaults only when the field is omitted; explicit null, non-integer values and out-of-range integers return the typed invalid-request failure. Task and Goal dispatch coverage reads a thread longer than the default page, follows its returned offset, checks the maximum limit, and rejects malformed values in both fields. Parse-only, `git diff --check` and the changed-line determinism gate passed locally. Independent adverse source review found no P1/P2 issue. Native execution of this repair remains pending CI.

The next native Test run, 34700788141 at `ebab73c4ddd8a5ad85a749b5df6d20abc9cc51d9`, exposed another fixture type error before any target suite ran: Board origin requires `Ids.Turn_ref.t`, not a formatted string. The fixture now uses `Ids.Turn_ref.make`; both origin and decision references were checked against the public signature, along with the test's Board, Goal, Task and verifier dispatch calls. Parse-only checks do not establish type correctness or behavioral success; the next native result remains required.

This source audit also corrected the malformed-pagination assertions: descriptor validation can reject a call before the source reader and returns a diagnostic message rather than source-error JSON. The tests now assert workflow rejection at dispatch and separately require typed `Invalid_request` from the reader for the same malformed input. Successful pagination still runs through actual Task and Goal dispatch.

Native Test 34701696883 at `cb51e87d719afffb171fbcc3faccb1572db9d400` compiled successfully: five of six collaboration cases and both other target suites passed. The last collaboration case stopped while creating a Direct Fusion fixture without its required explicit target. That fixture now explicitly addresses `@producer`, like the other Direct fixtures; Task and Goal access-denial assertions remain in place. Board post fixture creation now prints the typed Board error instead of discarding it as "post". The product's Direct audience and review-authority policies are unchanged. The repaired case still requires a new native CI result.

Native Test [34702739701](https://github.com/jeong-sik/masc/actions/runs/34702739701)
at `206c447685d97b27b09f0f7001c7e79be4846738` exposed a real workspace-authority
defect. Creating the second workspace config updated the test environment, so
`Board.persist_path ()` named the second workspace while the active Board backend
still held the first workspace's original posts. The reader compared two paths
derived from the same new environment and incorrectly allowed the foreign Goal.

The active store now carries the canonical directory captured before global
loading. All five persisted loaders use that captured directory. Standalone
in-memory `create_store ()` remains unbound and does not require workspace
configuration. Verification compares the requested workspace against the active
store's captured identity, and rejects an unbound store. The feature case now
checks both Task and Goal denial for Board and Fusion, verifies the original
workspace still reads its sources, and reloads the original post and comment
after the environment has moved to the other workspace.

Nine changed OCaml source/interface files passed parse-only checks, and
`git diff --check` passed. These are source checks; corrected native behavior
still requires CI. Existing Board writer path helpers remain environment-derived;
this repair does not establish full Board isolation during live workspace
reconfiguration. No runtime was changed.
