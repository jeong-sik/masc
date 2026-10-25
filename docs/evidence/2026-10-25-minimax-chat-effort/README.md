# Native M3.1 Chat depth control — #27924

The [official OpenAI SDK guide](https://platform.minimax.io/docs/api-reference/text-openai-api), directly read on 2026-10-25, documents five M3.1 depth values: low, medium, high, xhigh and max. Omission uses the provider default. M3.1 always reasons; none and explicit disable are disallowed. These documented contract facts are not observations of vendor acceptance.

At main c8e4a8d57e809acd55aea19799422e3b5f1e57bc, the native minimax/M3.1 row had thinking_control_format=none and no accepted effort ladder. The initial row-only repair enabled depth but regressed explicit enable with omitted effort at ordinary admission. Final source `34eced85849e37c20ab0c7113367b40a9735883d` declares an explicit categorical format with default-on semantics; it does not infer that default from a ladder or replay flag. M3, M2, Responses and hosted declarations remain outside this change.

## Final behavior and evidence scope

Reasoning_effort_default_on shares the existing categorical effort wire. Its explicit-enable-satisfied-by-default receipt distinguishes an already satisfied enable from an encoded field. Ordinary Reasoning_effort retains the requirement to encode an explicit depth when enable is requested. Disable still maps to none, then the model's declared ladder admits or rejects it. M3.1 excludes none/minimal/ultra. Its explicit split reasoning, structured streaming, preserve-always and inline-content carrier declarations remain intact. Toggle/default fields are outside the persisted replay contract; the four replay identity fields are unchanged.

The native fixture resolves the shipped provider/model without overrides. It checks public validate_all admission before final HTTP serialization for sync/stream, each documented depth with absent/true enable, omitted depth with absent/true enable, typed unsupported-depth and disable rejection, the default-on receipt, and an ordinary-format negative control. Omitted depth stays omitted on the wire. The existing nine-name native sync/SSE replay fixture remains in the same codec suite. This is not live provider evidence.

Runtime_schema aliases and Runtime_adapter preserve the new format. Runtime_toml accepts canonical hyphen/underscore spellings; the Dashboard declaration projection emits the canonical hyphen spelling exhaustively. Existing public parser cases cover both spellings. The new inventory fixture loads a temporary runtime file through Runtime.init_default, reads public runtime_inventory_json, then reparses the projected format. It uses no provider HTTP and proves data projection, not rendered UI.

## Preserved execution history

- Baseline run40200778570 at5908caa067647a60b856d42e1e1f23a0a2193385 actually ran65 codec cases:64 PASS/1 FAIL at documented effort admission. Later assertions in the new case were not reached.
- Intermediate run40200802107 at82102d347e20d7caaa049f040980b7171797b86a succeeded with codec65 + wiring1 =66 actual cases. Its fixture omitted full admission and missed explicit enable with omitted effort. Review found P2; this result is not certification of the final fix.
- Strengthened baseline run40201257211 atca93935a26dd2e5215811003f55914bbaed57150 actually ran65 codec cases:64 PASS/1 FAIL at full public admission. The omitted-effort/explicit-enable combination was the failure; later unsupported/disable assertions were unreached in that case.
- Review of d38903d28f255ff46cedc67c82fc05335c47976a found the missing exhaustive Dashboard projection branch and runtime parser aliases. They were corrected before final source. Run40201403430 actually passed codec65 + capabilities124 + provider config140 =329 selected core cases, then failed root compilation on that missing Dashboard variant (fatal warning8); its root suite did not run. This is a failed workflow, not329 successful root cases.
- dd5358dcae3ac9a220c1ccee977d882c0479f6cc added those consumers and parser cases; run40201598560 was dispatched. Final34ec additionally adds the public inventory roundtrip and run40201714511 requests codec, capabilities, provider config, runtime format parser and inventory suites. Dispatch is not execution success.

Selected checkout/assertion/suite lines and raw log SHA/size are retained in this directory. Local OCaml parsing, TOML decoding and whitespace checks were performed. No local Dune/typecheck/full build, full regression, installed runtime, deployment or vendor HTTP was run. Current-head source review is distinct from execution, formal independent approval and merge.

PR #45972 is an isolated bottom branch because #45859 was already merged. gh stack init adopted it; gh stack submit reported native stacks disabled, and REST stack:null was observed. Main advanced fromc8e4 to32b4c94120f04e0b970105e958ad10d2dbaf50ce with a docs/evidence/changelog-only delta. That is not a newly executed current-main combination.

Native Responses integration, exact M2 Responses availability, Chat tool-choice evidence and the rest of #27924 remain open. This incremental repair does not close that issue or the oldest-issues campaign.

## Actual final execution

[Run40201714511](https://github.com/jeong-sik/masc/actions/runs/40201714511) checked out exactly `34eced85849e37c20ab0c7113367b40a9735883d` and completed SUCCESS: codec65 + capabilities124 + provider config140 + runtime-format parser8 + public inventory2 = **339 actual cases**. Full admission with omitted/explicit depths, unsupported/disable boundaries, the existing native replay case, both parser spellings and the public inventory reload assertions were reached. Server projection compiled in this execution. This is data/protocol proof, not rendered UI or vendor HTTP.

Earlier [run40201598560](https://github.com/jeong-sik/masc/actions/runs/40201598560) atdd5358 actually succeeded338 (the inventory suite then had only its pre-existing one case). It predates the added inventory roundtrip and is not the final339 result. Counts from intermediate/failed runs are not added to339.

All19 source/fixture hashes in source-hashes.json match subsequent evidence/changelog-only heads. The first changelog check found the missing PR citation; it was corrected at44f679d4039e5f084c08fd06e4cab4b35398ba27 and check-files then passed. The earlier author COMMENT's mention of fragment checks was not a successful fragment receipt. No source or fixture changed for that correction. Full regression remains unexecuted.
