# Skills authoring and observation evidence

The source changes cover Skill creation, canonical composition authoring, retained
run discovery and statistics, failure details and both operator interfaces. This
bundle keeps selected proof in version control rather than relying only on ignored
local artifacts.

## Earlier integrated candidates

`prior-candidate/retained-files.json` identifies each retained file by byte count and
SHA256. The files are byte-for-byte copies of selected earlier candidate artifacts;
checks against the original proof index passed before copying. The
`original_index_match` flags record that historical check. The original ignored
worktree is no longer present at this final audit; current checks verify the
retained copies against their recorded sizes and hashes. These are not new
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
| [Dashboard node input/output](prior-candidate/dashboard-f411-final-node-input-output.png) | Completed parent and node input/output |
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
final head. Test41276822799 ran at
`3832592eea019048729fdd9422324144ee00744e`; Test41278694219 ran at
`d1bf030a57db615282003baba29a6a8ae70f3868`, both on the history branch and
both completed successfully. [Merge compile 41280443953](https://github.com/jeong-sik/masc/actions/runs/41280443953)
ran its launcher on main `01550209c9a932d3594f86ae9d5a4fb65956aebe`;
the successful `merge-compile` status is bound to target
`fcfd8d6484401d34344454e6dc84fc6dc902c65c` and reports four built operator
executables. These runs certify their stated source coordinates, not a later
audit head.

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

### Product source review at the matched candidate

The matched candidate product sources passed independent full-diff review at the
following immutable coordinates. Subsequent integration restacks require fresh
formal reviews and do not rename these source/build/UI snapshots:

| PR | Head | Base | Complete diff SHA256 (`masc-reviewed-git-diff-v1`) |
| --- | --- | --- | --- |
| 47159 | `94240d9c0d70d987aa167a28b32cf5903f1f7315` | `7c6dbe4fb58cecc0bce06a60069f18320f3b4968` | `b45605967cc69a4c1fbec0f6c2b0ec79d138b55f5d2dd7efa866fd9425bdbf30` |
| 47174 | `69c65ab0fd0484712ab118885ffcf20b4124d56d` | `94240d9c0d70d987aa167a28b32cf5903f1f7315` | `f67b61e6e4d18c8897ccba78a060ff7677210f42cca7efca4d90d05180848a10` |
| 47183 | `1047c150a3086190677bf4affb4cdde8cc82ed51` | `69c65ab0fd0484712ab118885ffcf20b4124d56d` | `afc72536f58002443e6140d6fdf7dbaf9641a01ae89e151f0dd26108789a8292` |

The review found and closed an additional P2: async TUI nested headings now use
the canonical terminal sanitizer for aliases and export names. Raw decoded
observations remain intact; the original-call reader and all bodies retain their
existing sanitizers. Actual Dashboard inspection also exposed undefined input
styles; the existing Skill input class now supplies boundaries and keyboard
focus to creation, lookup and filters. No UI text/layout assertions were added.

These are independent source verdicts. Formal non-author GitHub approval,
current-top merge compile and final integration remain separate facts.

### Matched completion candidate

The [matched proof index](current-candidate/candidate1047-matched-proof-index.json)
records source `1047c150a3086190677bf4affb4cdde8cc82ed51`. Its
[Mac probe](https://github.com/jeong-sik/masc/actions/runs/41294630269)
completed successfully: all 14 downloaded manifest entries passed SHA256 checks,
and both server and TUI embedded commits matched. Dashboard assets were built
from a clean checkout of that same commit; all 688 file identities are retained.
Actual served HTML, module, stylesheet and vendor bytes matched those staged
assets. The direct build identity and byte checks provide this binding; full
executable-binding metadata in health remains absent.

| Retained actual screen | Observation and scope |
| --- | --- |
| [Catalog precedence](current-candidate/dashboard1047-final-name-precedence.png) and [shadow filter](current-candidate/dashboard1047-final-shadowed-filter.png) | Two same-name packages, one server-selected winner, one exact shadow; filter shows one of two |
| [Input styling before](current-candidate/dashboard183-before-input-styles.png) | Matched earlier183 candidate before defining the existing input class; separate from1047 captures |
| [Guided parser preview](current-candidate/dashboard1047-guided-preview-result.png) | Explicit audit-second source, chosen tool, fixed JSON input and named output; actual server validation, no create/publication or execution |
| [Dashboard completed children](current-candidate/dashboard1047-final-completed-children.png) | Actual native async result copied to an isolated read store with only base_path rebound |
| [TUI completed request](current-candidate/tui1047-completed-lookup.png) and [node/exports](current-candidate/tui1047-completed-exports.png) | Same exact request through the actual editor lookup path, with physical completion, missing original journal and available child outputs kept distinct |
| [Dashboard parent read carrier](current-candidate/dashboard1047-final-parent-failure.png), [admission rejection](current-candidate/dashboard1047-final-rejected-children.png) and [unstarted child](current-candidate/dashboard1047-final-unstarted-child.png) | QA terminal carrier contains unchanged actual native INLINE failure data; the carrier is not evidence of a native async worker failure |
| [TUI failure carrier](current-candidate/tui1047-failure-lookup.png) and [rejected/unstarted children](current-candidate/tui1047-unstarted-child.png) | Same explicitly seeded read carrier, including pre-effect node failures and individually unavailable exports |

The native inline failure result contains two completed siblings, one admission
rejection and one unstarted child. Its domain data, original aliases, activation
frames, run and node identities remain unchanged. The physical carrier's new
request ID, clock, status and absent composition context are explicitly QA data.
The [carrier receipt](current-candidate/candidate-failure-read-carrier.json)
and actual [HTTP failure response](current-candidate/candidate1047-http-failure.json)
retain that distinction. No model or worker was replayed.

The copied genuine async terminal record retains its actual source physical
completion. Its original native canonical status records a newer logical owner;
the isolated store did not receive that journal, so its actual current HTTP
response says `unavailable/missing_journal`. These observations are not merged
into a continuity claim. Native source identity `fixture` is separate from the
audit-first/audit-second catalog collision identities.

[Native/security Test41295012653](https://github.com/jeong-sik/masc/actions/runs/41295012653)
passed 404 cases in four named suites at current native69c65ab0: 14 nested,
11 original reader, two async reader and 377 existing decoder/security cases.
Fresh final Dashboard checks passed 274 cases across 15 distinct files in four
disjoint selections, plus TypeScript. The retained individual logs and
[verification record](current-candidate/dashboard-final-current-verification.json)
state those populations. The earlier279-case/13-file selection above is a
separate earlier source check, not a renamed final run.

TUI operated at60x188 in identified ttyd1.7.7 with xterm-256color/Menlo14. A
deterministic QA editor copied each explicit target JSON through the actual
external-editor round trip; this is not a claim of interactive VI behavior.
The retained gzip decompresses byte-for-byte to the original455224-byte raw
terminal capture; its uncompressed SHA256 is in the proof index. Screenshots
were visually inspected without image edits. The browser space was finished
with no kept pages; owned processes stopped, both QA ports closed and private
token captures were removed. The paused fixture stayed at zero turns and zero
Keeper fibers. This is not a healthy production fleet or an installed release.

The [current-locations sidecar](current-candidate/current-locations.json) verifies
35 selected capture copies without rewriting the original path/hash manifest.
The evidence layer also retains its four native producer-to-Dashboard parity
cases. Integration waits for current-scope formal approval and merge compile.

## Scope and limits

Earlier screen statistics used five manually seeded retained runs with a paused
Keeper, zero turns and zero fibers. They prove candidate UI and request behavior,
not real model execution, production deployment, fleet-scale performance or user
objective success. New nested execution proof must state its own producer and
consumer provenance. Prepared recipes and run-binding artifacts are definitions
and invocation evidence; they do not establish completion. Retained coverage
remains incomplete even when every observed run is counted correctly.
