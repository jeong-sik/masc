# Canonical Policy dependency for post creation

A second store can change a sub-board from Open to Owner_only without changing
Posts. The old create path checked only cached policy and the Posts write CAS,
so the first store could still append an unauthorized scoped post. This is a
source counterexample, not an installed incident or executed backend failure.

## Source and stack

- Main/source base: `9188d8050faf685b4614976f131d85832b6fdd39`.
- Production source: `36cdb66c69c0202ba3f36996548f716f1f7239ce`.
- Test source: `3e33991e21dd7137d916ea6151cffaa62152d00a`.
- Native Stack #51158: #51156 then #51157; target main, integrate whole through top.

The source was first reviewed at lower `86316` / upper `6310` on parent `702d`. Once #51146
and #51147 were observed merged, the unpublished child was reconstructed on main
without reintroducing that parent diff. Twenty of its 21 changed paths and every
changed ML/MLI are byte-equal; test/dune additionally inherits three unrelated
main lines. Both readers checked this delta. `reconstruction-on-main.json` retains
exact pins, paths and hashes. Subsequent changelog/evidence-only commits do not
change the captured 17 ML/MLI inputs.

## Resulting boundary

The shared pure Policy capture decodes the authoritative snapshot in physical row
order and checks the original post/comment author. An unregistered hearth still
has a Policy absence dependency. An unscoped post has none.

Scoped creation holds Posts then Policy stable scopes through the existing
append body. The body receives the normalized target directory/path and original
target IO, and still verifies cursor, full bytes and data binding. It does not
reacquire Posts. The worker helper is hidden from the public Fs_compat interface;
the public addition is a narrow append with one distinct read dependency.

Outer Posts refusal, inner Policy refusal and the actual append result remain
separate. Only actual inner refusal is delivered to the Policy owner by the create
caller, preserving module dependency direction. A known append publishes its
source receipt and model before reserved cleanup propagates. Actual unknown
append results reuse the existing unsettled-write path. Ordinary pin/close/reopen
retain their own append path and are not subjected to post-creation policy.

| Changed interface | Direct consumer | Verification |
| --- | --- | --- |
| Private locked append body | FS dependency guard | Full source read; parse-only |
| Nested dependency append result | Posts source creation append | Full source read; parse-only |
| Creation result and guard diagnostic | Create caller, source finish, two existing diagnostic matches | Full source/MLI read; parse-only |
| Pure canonical Policy capture | Post and comment admission | Full source/consumer read; parse-only |
| Public create/curation and real IO seams | Eight new feature cases | Source only, no execution |

## Evidence and limits

`validation.json` is copied without editing from the final local receipt. All 17
changed ML/MLI inputs parsed with OCaml 5.5.1; repository target is 5.5.2. Whitespace
and the Dune include source census passed. The receipt's raw textual count of 945
includes one commented example; there are 944 active include entries. The new
suite is registered once and no active duplicate include was found. Dune itself
was not run.

Two independent local agents read all 18 production paths and 3 case paths and
found no additional confirmed P0-P2. Their source verdicts and main-base reuse
scope are in `source-reviews.json`. They did not build, typecheck, execute backend
cases or submit a formal GitHub approval.

The eight new cases describe foreign policy restriction, a newly registered
restricted slug, unavailable Policy for unscoped creation, live Posts/Policy
locks with exec children, known append plus Policy cleanup, original data-FD IO,
inner refusal plus reserved outer cleanup and existing curation. **All eight are
unexecuted.** There is no new actual unknown-fault case, so these cases do not
supply unknown-effect execution evidence. Initial source review corrected the
extracted success binding and the existing Already_voted constructor argument;
those corrections are source checks, not observed compiler failures or red/green
backend results.

There are no frontend changes or new frontend executions. The entire Dashboard
tree remains `7bb15ad1fcf789424d2077130511300ef144356f`, equal to the earlier named
105-case/tsc/ESLint receipt in the sub-board deletion evidence bundle. That retained
frontend receipt does not prove new backend or browser integration.

No OCaml typing/warnings/build, backend execution, new browser/live HTTP, CI,
installation, deployment or root #26378 completion is claimed. Formal approval,
integration and runtime behavior remain separate observations.

## Remaining issue scope

#26378 remains open for existing-parent existence/readership dependencies where
votes/reactions require them, actual cleanup selection condition changes,
usage-based disposition of Posts source-only settlement, and backend
failure/multiwriter/restart evidence. Original #26415 waits behind that issue.
