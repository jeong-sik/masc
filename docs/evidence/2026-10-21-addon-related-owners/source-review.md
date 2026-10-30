verdict: PASS head: c54fd2515c0901c63ebe19069153a7bf4d46e156 by: bidi_partial_failure_response

Independent SOURCE review for the bounded G04 related-worker detail unit.

- Base: `ad6ca89213d57c9ac978e1f3e5704292c4334cf6`.
- Canonical full diff identity (`masc-reviewed-git-diff-v1`): `3e55ee8d2f33035d44071aaca8f1c9823a058c96e337b7fb546b9e97be61cafb`.
- Initially read all5 uncommitted implementation/test files, then observed the author commit6516c881 and additionally read its complete worklist delta. That initial verdict bound the full6-file immutable diff at6516c881. Current verdict additionally reads the final two metadata files and binds the full7-file PR diff atc54fd251 (153 additions,26 deletions).

No unresolved P0, P1 or P2 found in this scope.

Direct source checks:

1. TUI `connection_workers` reuses original instance records without constructing altered worker identity. Managed workers join the selected installation ID even if its source path moved. The second group requires both a different non-null installation ID and exact equal non-null source path. The groups are disjoint and never join by title/run/package/basename or inferred chronology.
2. Manual attachment matches only selected instance ID plus incarnation. Missing source and missing installation IDs do not join manual attachments together; a replacement incarnation does not satisfy the original manual observation. New tests inspect these returned record groups and retained original metadata, adding no TUI wording/layout assertion.
3. The new read model appears in ML/MLI with the same fields/signature, and snapshot/item/worker parameters are explicitly typed. It adds no duplicated id/source_path option-record labels and changes no existing record constructor. The option-pair classifier explicitly covers every shape. Source searches found only its intended renderer and test call sites; no omitted required consumer was identified.
4. Dashboard `workerRecord` is reached only after configuration-bearing group filters. The actual schema requires configuration as object-or-null, so those call sites justify the non-null reads. Each separate owner retains actual installation ID, instance, incarnation, source path, installed revision, runtime presence, phase and observation sequence.
5. Dashboard application selection still requires one unique declaration matching both selected installation ID and source path, plus expected source revision when provided. Another ID at the path is rendered separately without supplying the selected declaration's application. The new missing-selected-declaration regression directly checks that separation.
6. Inspected direct Dashboard manager/activity-panel callers and TUI detail/selected_instance/can_observe/action_target/open_actions/submit_action paths. The new groups feed only detail rendering. Existing exact instance/incarnation and action-schema matching remains the submission authority; no relationship grants actions or changes selection. Original worker/application/receipt paths are retained.
7. The worklist delta keeps G04 bounded and states actual Dashboard checks separately from parser-only TUI and unexecuted OCaml/UI. It does not replace G01's frozen source or pending execution evidence, or claim54-item completion.

Evidence limits: author reports three Dashboard files/62 tests and tsc exit0 plus three OCaml parser passes. This reviewer did not rerun or independently audit those execution logs. No OCaml typecheck, build, tests, CI queries/dispatch, runtime or actual UI actions were performed. No code, Git refs or GitHub state was changed; only this requested /tmp review record was written. This is not formal GitHub approval, whole-worklist completion or a verdict on later changelog/rebase heads.


Final bottom metadata binding for PR #44807:

- Independently read the complete6516c881→c54fd251 delta. The only added file is `changelog.d/44807.md`, using accepted `### Fixed` and its own `#44807` citation. Its description matches the read-only relationship grouping and preserved application/action authority.
- The worklist's G04 explanation is moved from EOF to the G section, linked to #44807, with the substantive paragraphs and execution/UI limitations unchanged. It does not add or remove any54-item task or claim new execution.
- All five implementation/test blob IDs equal the previously read6516c881 objects. The complete source review is explicitly carried from that earlier head for those identical files, with this final metadata delta newly read.
- No new P0, P1 or P2 found. Base remainsad6ca89213d57c9ac978e1f3e5704292c4334cf6; this is the final local bottom source, not the future evidence layer or remote formal approval. No build/typecheck/tests/CI were run or queried for this response.
