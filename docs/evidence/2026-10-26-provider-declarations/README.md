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
