# Checkpoint carrier fixture repair: observed main evidence

The observed checkout is `2c3a9f701afd57cd0f62deb853325cb0197e0432`. It includes the previously approved Task/Goal publication and three-test consumer repairs. Results here precede the two checkpoint-fixture field additions.

| Check at that exact checkout | Actual result | Original run |
| --- | --- | --- |
| Four operator executables | SUCCESS, four targets executed; successful-input receipt MISS | [40101563242](https://github.com/jeong-sik/masc/actions/runs/40101563242) |
| Eight selected behavior suites | 16/39/18/9/23/15/4/22 = 146 OK, 0 FAIL/SKIP/TODO | [40101567388](https://github.com/jeong-sik/masc/actions/runs/40101567388) |
| `dune build @check` | FAILURE: two checkpoint fixtures omit required `content_carrier` | [40101565461](https://github.com/jeong-sik/masc/actions/runs/40101565461) |

The [four-product receipt](main-four-products.json) and [actual build excerpt](main-four-products-build.log) cover server, TUI, browser host and deployment-preflight helper. The workflow ran from main with pr0, `proof_only=false` and no toolchain override. Canonical workflow input digest is `cb354fa2f019ef2fd315a76561f601b1db12765d497965f29d6137768cc9c8d3` over13,905 tracked entries after the workflow's documentation exclusions. Cached Opam/Dune intermediates do not make this a clean rebuild. Artifact12562624751 ZIP is368bytes, SHA256 `969702d835b644de8c8f0bfc52420255018d1e25e7391bc852a4db3968e5ab90`.

The [actual eight-suite runner](main-eight-suite.log), [case counts](main-eight-suite-counts.json), and [critical source/assertion mapping](main-eight-suite-critical.json) come from a single new execution at2c3. The suites are Goal worker, Goal verification agent, retained verifier worker, completion trust harness, verification registry, output-token receipt, native result retention, and anti-rationalization empty-reject. All eight executable builds, starts, summaries and terminal OK markers were checked. This146 is not a sum of earlier105 and41 executions. Artifact12563101573 ZIP is27,051bytes, SHA256 `b322172a6158f0199f45236845490467ed12783b957d0293b55aa5eba3fb535c`; runner is196,925bytes, SHA256 `13ec8c20a9aac0c04928f327c4d7f2b2a1215e8a68ecb94dab16e764c783f933`.

Case17 remains one counted case containing three retained phases, each with missing-observation and observed branches. Scoped observe/apply counters, separate production-entry refusal/state checks, and successful Task/Approved/ACK checks retain their distinct measurement boundaries. Provider serializer combinations are fixtures, native-retention calls use the actual implementation, and reviewer callbacks are injected. No actual provider HTTP, model call, Board delivery, or operational restart is inferred.

The [failed type-check receipt](main-check-failure.json) and [two compiler diagnostics](main-check-two-errors.log) preserve the actual missing required field in `test_checkpoint.ml` and `test_checkpoint_delta.ml`. Full original job log SHA256 is `57cfcfe6db66b034b800946f13deeea743a55777da606cdf63612b741ad62b32`. This is a type-only lane, with no executed test cases.

The source repair explicitly sets `content_carrier=Canonical_blocks` in the two existing producer-binding fixtures. The persisted replay contract requires a closed carrier value. These fixtures exercise text-only binding persistence and endpoint identity deltas; they contain no inline reasoning artifact. Their other fields, fixture values, strict negative checks, assertions and Dune declarations stay unchanged. No product decoder fallback or compatibility conversion is added. Parser-only validation passed for the two changed files; this record does not claim repaired typing or checkpoint-suite execution.

[manifest.json](manifest.json) records the preserved evidence file lengths and hashes. Source review, type checking, selected behavior, integration, installation, actual providers and deployment are separate. The successful build and146 selected cases do not erase the failed type check and do not establish full regression success.

The critical-assertion JSON retains original audit-bundle provenance paths under `source/`; those paths are not promised as local copies in this directory. The exact frozen source is available at the links below, with the recorded source hashes in the JSON. The [case17 companion](case17-critical.json) is included here.

- `source/test_anti_rationalization_empty_reject.at-2c3a9f7.ml`: [test/test_anti_rationalization_empty_reject.ml](https://github.com/jeong-sik/masc/blob/2c3a9f701afd57cd0f62deb853325cb0197e0432/test/test_anti_rationalization_empty_reject.ml)
- `source/test_keeper_native_result_retention.at-2c3a9f7.ml`: [test/test_keeper_native_result_retention.ml](https://github.com/jeong-sik/masc/blob/2c3a9f701afd57cd0f62deb853325cb0197e0432/test/test_keeper_native_result_retention.ml)
- `source/test_output_token_receipt.at-2c3a9f7.ml`: [packages/agent_core/test/test_output_token_receipt.ml](https://github.com/jeong-sik/masc/blob/2c3a9f701afd57cd0f62deb853325cb0197e0432/packages/agent_core/test/test_output_token_receipt.ml)
- `source/test_verifier_review_worker.at-2c3a9f7.ml`: [test/test_verifier_review_worker.ml](https://github.com/jeong-sik/masc/blob/2c3a9f701afd57cd0f62deb853325cb0197e0432/test/test_verifier_review_worker.ml)
