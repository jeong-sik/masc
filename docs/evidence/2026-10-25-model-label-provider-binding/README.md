# Model-label provider authority — #27898

At main25ba22387ffe0d71be8e0f8e58cb66b4bfa5237a, Runtime_model_string resolves a provider registry entry, but constructs Provider_config without its provider id. It also selects max_context through Capabilities.for_model_id, a provider-unqualified lookup. Thus the config's typed provider authority differs from the explicit label, and context can come from an unrelated bare row. These initial findings were source observations, not successful baseline execution.

## Repair

The returned config now carries the canonical registry entry.name. It obtains the context window through Provider_config.context_window on that same provider-bound config, with the existing provider-level max_context fallback. The code no longer queries bare-model capabilities separately. Endpoint overrides do not rewrite that provider id. No new inference, mutable registry or compatibility adapter is added.

Request preparation still owns policy freezing. This repair does not consolidate the mutable provider registry, runtime binding defaults, local auto discovery, custom URL semantics, manifest and whole catalog graph. It is a concrete remaining caller correction toward the original hard cut; #27898 stays open.

## Public scenario

The new suite builds one strict synthetic catalog with a bare overlap row and two providers declaring the same model/wire. Provider A has an8192 context and rejects forced tools, B has32768 and permits forcing, while the unrelated bare row advertises1000000. The public provider:model parser must retain each identity, context and tool policy. An endpoint override on A must not borrow B's policy. Admission rejects A's required choice; B's final Common HTTP serializer emits required with a normalized tool definition. This uses no network or production credential.

## Execution boundaries

Initial test-only cf2ded621b1dbb1a8dda8d5c56afab3e875692b1 run40202800205 and initial corrected3bcbd771ef6ff077b90e79154759fdcaec2cfaea run40202867564 failed compilation on Unbound module Yojson. No cases ran in either. Adversarial review independently found the missing direct dependency under implicit_transitive_deps=false; the stanza now declares yojson.

The dependency-corrected regression-only branch70af248f3ef65b221f025b9f6f4ad79dbf973c62 preserves main production and requests run40203036289. Corrected source97f5295e2481755c168f244ca6bf8e6216a4ea7c requests run40203029288. Both request only test/test_runtime_model_label_binding; actual outcomes are recorded separately after observation. The corrected source also adds endpoint-override controls absent from the original baseline fixture.

Changed OCaml files parse and whitespace passes; those are not typecheck or behavior results. No local Dune/typecheck, full regression, vendor HTTP, installed runtime, deployment or whole-issue completion claim. Five source/fixture hashes are retained. gh stack init adopted this bottom branch; submit reports native stacks disabled, REST stack:null. PR #45980 is unmerged; source reviews and formal independent approval remain distinct.

## Actual corrected execution

[Run40203029288](https://github.com/jeong-sik/masc/actions/runs/40203029288) checked out exactly97f5295e2481755c168f244ca6bf8e6216a4ea7c and completed SUCCESS with **3 actual cases**. Identity, both provider context limits, independent tool admission, endpoint override policy retention and B's final required-tool body assertions were reached. This is a focused public-path proof, not full regression or runtime/provider execution. The regression-only baseline result is recorded below.

## Actual behavioral baseline

[Run40203036289](https://github.com/jeong-sik/masc/actions/runs/40203036289) checked out70af248f3ef65b221f025b9f6f4ad79dbf973c62 and ran **3 actual cases, all3 FAIL**. Identity expected Some label-a but received None. Context expected Some8192 but received Some1000000 from the unrelated bare row. The policy case failed because provider model capabilities were absent, before forcing/HTTP-body assertions; it does not prove a forced tool was sent under the wrong policy. Those later assertions were reached only in the corrected successful run.

The corrected candidate's endpoint override assertions are additional controls and were not in that baseline fixture. All5 source/fixture hashes remain unchanged in subsequent evidence-only heads. No skipped/unreached assertion is counted as a baseline pass. Both initial compile failures remain distinct from this actual three-case behavior failure.
