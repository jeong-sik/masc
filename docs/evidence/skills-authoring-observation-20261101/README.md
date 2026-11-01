# Skills authoring and observation evidence

The source changes cover Skill creation, canonical composition authoring, retained
run discovery and statistics, failure details and both operator interfaces. This
bundle keeps selected proof in version control rather than relying only on ignored
local artifacts.

## Earlier integrated candidates

`prior-candidate/retained-files.json` identifies each retained file by byte count and
SHA256. The files are byte-for-byte copies of selected earlier candidate artifacts;
checks against the original proof index passed before copying. They are not new
captures of the completion-audit changes.

- Visual candidate: `f41185329e3d9b8778b8053ef44a4ce37597fb8f` (matched server,
  Dashboard and TUI).
- TUI authoring and request-ownership candidate:
  `3832592eea019048729fdd9422324144ee00744e`.
- Final earlier compiled head: `fcfd8d6484401d34344454e6dc84fc6dc902c65c`;
  integrated commit: `e2492b345dc5f322868b15ec22c7e7b014df629f`.
- The compile and integrated trees matched
  `5acb66504e8e007be4d16aa8fda71defce6beee1`.
- Integration: [47036](https://github.com/jeong-sik/masc/pull/47036),
  [47041](https://github.com/jeong-sik/masc/pull/47041),
  [47074](https://github.com/jeong-sik/masc/pull/47074),
  [47086](https://github.com/jeong-sik/masc/pull/47086),
  [47099](https://github.com/jeong-sik/masc/pull/47099) and
  [47108](https://github.com/jeong-sik/masc/pull/47108).

| Retained proof | What was observed |
| --- | --- |
| [Dashboard history and statistics](prior-candidate/dashboard-f411-final-history-statistics.png) | Exact retained run selection and outcome-specific duration populations |
| [Dashboard node input/output](prior-candidate/dashboard-f411-final-node-input-output.png) | Selected parent failure and node evidence |
| [Dashboard composition preview](prior-candidate/dashboard-f411-final-composition-preview.png) | Guided canonical inputs, dependencies and outputs through parser preview |
| [TUI history](prior-candidate/tui-f411-final-direct.png) | Retained original run navigation and statistics |
| [TUI failure/node detail](prior-candidate/tui-f411-final-failure-node-evidence.png) | Failure reason and exact selected node evidence |
| [Dashboard authoring proof](prior-candidate/dashboard-f411-authoring-preview-proof.json) | Preview of a guided composition candidate |
| [TUI authoring round trip](prior-candidate/tui-authoring-roundtrip-proof.json) | Source choice, editor, publication and source/catalog readback |
| [Actual TUI wire navigation](prior-candidate/wire-after-fix-proof.json) | Dispatcher sent latest/exact selectors; delayed earlier replies did not change the selected result |
| [Draft retention](prior-candidate/dashboard-draft-filter-proof.json) | Filtering and restoring a Skill retained the same unsaved editor draft |

Focused native behavior checks:
[Test 41276822799](https://github.com/jeong-sik/masc/actions/runs/41276822799)
(797 cases),
[Test 41278694219](https://github.com/jeong-sik/masc/actions/runs/41278694219)
(587 cases). Dashboard type checking and 113 focused cases passed at the earlier
final head. [Merge compile 41280443953](https://github.com/jeong-sik/masc/actions/runs/41280443953)
built its four operator executables. These runs certify their stated source
coordinates, not a later audit head.

## Completion audit

The full goal was reopened after the earlier integration. The audit found two
missed P2 requirements: Dashboard catalog name precedence was invisible, and
actual nested execution results still required reading raw JSON. The correction
is recorded in [47033](https://github.com/jeong-sik/masc/issues/47033#issuecomment-6555157896).
[47159](https://github.com/jeong-sik/masc/pull/47159) repairs published name
precedence; [47174](https://github.com/jeong-sik/masc/pull/47174) adds the native
nested observation and TUI consumers.
[47183](https://github.com/jeong-sik/masc/pull/47183) supplies the Dashboard
original-result and retained-request consumers. These observations reuse the
existing exact Skill reference, activation frame, nested scopes, executor
settlement, original result pages and blob authority.

### Actual native producer and Dashboard parity

[Test 41291355669](https://github.com/jeong-sik/masc/actions/runs/41291355669)
passed all 27 cases at `26e713fa41de5f6a96a8a98597ea96c95cef523a`: 14 native
nested composition cases, 11 original-call reader cases and two async-request
reader cases. The native tests invoke the public prepare/run path and emit the
unchanged resulting records. The retained `native/` files preserve the source
log and selected parsed payloads; `native/current-locations.json` identifies the
current copies without rewriting their original capture manifests.

The compact checked-in fixture
[`skill-nested-native-observation.json`](../../../test/fixtures/skill-nested-native-observation.json)
retains completed inline children, completed and rejected/unstarted siblings,
and the full actual async status. Four Dashboard parity cases consume these
native outputs. They check exact admissions and activation frame hashes, scope
mapping, individual node results, available/unavailable exports and the distinct
physical request and newer logical owner. The full focused Dashboard run passed
279 cases in 13 files, with TypeScript checking, at the product source tip
`183b33f4d1939535b243a15b9aad9c69fc98a89f` plus the verification-only fixture
and test. These checks do not imply a browser HTTP request or a model execution.

The source document UTF-8 SHA256 is
`16d761952b1ecd2e0a2e588080f909676b14886d728e92915694bb27b88fca68`;
its typed Skill content revision is
`45eb9509e7073bac18e4e997e9e5bf6288889364e6dc5103e53e3317b823dfe8`.
The latter uses the existing length-prefixed `skill_document` field codec.
These identities are intentionally distinct.

Current candidate screen proof and final integration are recorded separately
when verified.

## Scope and limits

Earlier screen statistics used five manually seeded retained runs with a paused
Keeper, zero turns and zero fibers. They prove candidate UI and request behavior,
not real model execution, production deployment, fleet-scale performance or user
objective success. New nested execution proof must state its own producer and
consumer provenance. Prepared recipes and run-binding artifacts are definitions
and invocation evidence; they do not establish completion. Retained coverage
remains incomplete even when every observed run is counted correctly.
