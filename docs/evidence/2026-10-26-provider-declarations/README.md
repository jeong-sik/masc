# Provider declaration snapshot — #27898 / #46009

The registry and runtime metadata previously captured the model and provider
catalogs independently, then joined defaults/capabilities/availability through
a freshly constructed registry. Runtime all/find also read those catalogs
again. They now project one immutable admitted Provider_declarations view.

## Admission and consumers

The pure `of_catalogs` boundary consumes explicitly supplied admitted TOML/JSON
catalogs. An overlay replaces only the same case-equivalent canonical id and
removes the seed's aliases. Every other id/alias collision returns a typed
Conflicting_identity. Missing capability presets return Unknown_capability_base;
invalid combined globals raise the typed invariant error through legacy
registry/metadata entrypoints instead of loading an empty or partial registry.

The data preserves declared spelling. Registry keys remain exact; lookup and
replacement keys fold ASCII case, and runtime bindings keep their existing
normalized ids/aliases. Initial source review missed an exact registry spelling
regression; another reviewer found it against the existing Acme-Cloud fixture.
The fix and eighth new case preserve those separate established contracts.
The initial PASS is superseded. No executed spelling failure is claimed.

Static credential source is data. Environment credential availability is read
only at the projection/query edge. Capture reads each global source once;
separate catalog updates are not an atomic transaction. Models, manifest,
concrete request-policy resolution and complete request-binding consolidation
are outside this provider metadata boundary.

## Focused verification request

- Provider_declarations → admitted identity/index/auth/endpoint record →
  Provider_registry and Provider_runtime_binding → test_provider_declarations,
  test_provider_registry, test_provider_runtime_binding.
- Runtime metadata/default/auth projection → model label config construction
  and auth eligibility → test_runtime_model_label_binding and
  test_runtime_binding_auth_available.

[40220623907](https://github.com/jeong-sik/masc/actions/runs/40220623907) was
dispatched for exact17fabe839cc3c0cdbeb7c0094490f228052a3959 and exactly
those five suites. Its result is unverified. Eight new cases cover replacement,
old aliases, declared spelling, cross-source collisions, missing preset,
invalid-global refusal, selected request construction after source replacement,
and credential observation. OCaml parsing, whitespace and an independent
Python check of the shipped27-provider identities passed. These syntax/data
checks are not OCaml type/behavior execution. No local build/typecheck ran.

## Parent fixture and restack

Parent #46006's [40219615509](https://github.com/jeong-sik/masc/actions/runs/40219615509)
actually executed binding28 PASS, Pipeline67 PASS/1 FAIL and MASC consumer3
PASS atc891e4aa26830a1622d96d3ca5f7525c6d24300b. The Pipeline fixture
expected native streaming from an undeclared test endpoint, so production's
conservative sync fallback left the native capture id absent. Parent49d7861
now declares minimal streaming support in its positive control and asserts both
real custom-transport choices: one native stream with exact trace id when
declared, one sync call and no stream when undeclared. Two source reviews found
no remaining fixture P0–P2. Its corrected request40220868585 is unverified.
The parent production implementation did not change.

The full local stack was rebased once after that parent fix and its three
layers were pushed atomically with explicit leases. This layer became31c54f850a382c4c0d82bb08b5e86500952833a4 over49d7861. Its provider
implementation and all five suites' source inputs are byte-identical to17fabe;
only the parent's separately selected Pipeline fixture moved. The manifest
binds twelve current production/fixture/dependency inputs. Native stack submit
reported disabled; REST membership is checked independently. Formal approval,
merge, native HTTP, installed runtime, deployment, full regression and whole
#27898 completion are not claimed.


## Actual execution and removal of duplicate inventory

[40220623907](https://github.com/jeong-sik/masc/actions/runs/40220623907)
checked out exactly17fabe839cc3c0cdbeb7c0094490f228052a3959. The workflow
FAILED with **100 PASS / 1 FAIL** across101 actual cases: registry45 PASS/1 FAIL
(out of46), new snapshot8 PASS, runtime binding28 PASS, model labels15 PASS,
auth4 PASS. Failure was the old fixed production provider-name list, which
omitted already-declared MiniMax. It was a test/data duplicate, not an observed
provider omission or snapshot projection defect. Parent source already iterates
all admitted provider rows and declares MiniMax; that is a source comparison,
not an executed parent-registry baseline.

The duplicated26-provider inventory and its snapshot assertion were removed.
Semantic shipped-provider capability/endpoint checks and exact overlay/key/alias
checks remain. A new independent two-provider fixture constructs explicit seed
and overlay declarations, retains both through registry/runtime projection and
actual config construction, and checks distinct identities, endpoints and
reasoning policies. Nine snapshot cases and45 registry cases are now requested;
the changed fixture counts do not relabel the old46-case failure as success.
Two source reviews confirmed the removal/functional coverage and found no
remaining P0–P2. Prior source PASS missed the inherited inventory assertion and
is superseded. Production remains byte-identical to17fabe.

[40221415380](https://github.com/jeong-sik/masc/actions/runs/40221415380)
was dispatched at exact8e9c17904710dc1ccc7822ac321bb3b62b5e3650 for the
same five explicit suites. Its result is unverified. The new corrected manifest
binds13 direct source/fixture/data inputs, including models.toml. The original
12-input manifest remains historical; it does not certify the changed fixtures.

## Actual parent correction success

[40220868585](https://github.com/jeong-sik/masc/actions/runs/40220868585)
checked out exactly49d7861c95dff413810fbab99f70b2f3d95637ff and completed
SUCCESS: **99 actual cases PASS** (binding28 + Pipeline68 + MASC consumer3).
The actual native/sync selection assertions executed twice inside the Pipeline
case: declared streaming carried the exact trace id; undeclared support used
one synchronous call and no native stream. This repairs the earlier Pipeline
fixture failure, which remains recorded above. It is a parent execution,
separate from the provider-snapshot five-suite request. No provider HTTP,
installed runtime, whole build/regression, formal approval, merge or issue
completion follows from99 focused parent cases.


## Actual corrected provider snapshot execution

[40221415380](https://github.com/jeong-sik/masc/actions/runs/40221415380)
checked out exactly8e9c17904710dc1ccc7822ac321bb3b62b5e3650 and completed
SUCCESS: **101 actual cases PASS** (registry45 + runtime binding28 + snapshot9
+ model labels15 + auth4). Independent providers survived registry/runtime
listing, alias selection and actual config construction with their own identity,
endpoint and reasoning policy. Replacement/old-alias removal, exact registry
spelling, typed collision errors, missing preset refusal, global fail-fast,
immutable captured selection and explicit credential observation controls ran.

All13 corrected source/fixture/data hashes match that executed source and later
evidence-only heads. The first100 PASS/1 FAIL result remains a failed historical
workflow; the removed fixed inventory was not repaired into a pass. The changed
45/9 registry/snapshot counts are explicit. Parent99 remains a separate source
execution, not added to101. No local build/typecheck, live provider HTTP,
installed runtime, full executable/release build, full regression, formal
approval, merge or complete #27898 hard cut follows from these focused results.
