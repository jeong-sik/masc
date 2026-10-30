# Captured main check and minimal test-consumer repair

The frozen checkout is `fde6f30f922bb5613f3cfea75be05fe2c833ce61`. It contains the requested integration cohort, including the two Task/Goal terminal-publication repair PRs. Execution results below belong to that checkout, before this three-test repair.

| Check | Actual result | Original run |
| --- | --- | --- |
| Four operator executables | SUCCESS; build command executed, successful-input receipt MISS | [40099127438](https://github.com/jeong-sik/masc/actions/runs/40099127438) |
| Five selected Goal/Task suites | 16 + 39 + 18 + 9 + 23 = 105 OK, 0 FAIL/SKIP/TODO | [40099132022](https://github.com/jeong-sik/masc/actions/runs/40099132022) |
| `dune build @check` | FAILURE in three test consumers | [40099129775](https://github.com/jeong-sik/masc/actions/runs/40099129775) |

The build targets are `bin/main_eio.exe`, `bin/masc_tui.exe`, `bin/masc_browser_host.exe`, and `bin/deployment_preflight_helper.exe`. The [structured build receipt](main-four-products.json) records `proof_only=false`, `toolchain_override=false`, `pr=0`, and `workflow_ref=refs/heads/main`. The [actual command excerpt](main-four-products-build.log) preserves the four targets. Opam/Dune intermediates were reused; this is not a clean rebuild or binary-installation claim. Artifact12562087855 ZIP is 368 bytes, SHA256 `019e2d1cca4005430ff93250fbf26acef54f98ef666b780fa7e408734a51d5d6`.

The five selected suites are `test_goal_verifier_worker`, `test_goal_verification_agent`, `test_verifier_review_worker`, `test_completion_trust_harness`, and `test_verification_run_registry`. The [actual runner](main-five-suite.log), [suite counts](main-five-suite-counts.json), and [critical assertions](main-five-suite-critical.json) belong to the new main run. Artifact12561928615 ZIP is 23,887 bytes, SHA256 `1c6bfed84a1614ae7429c2e2abe92dc59a5545e8ef581ae08ce12012a0b8d3ee`. Its runner is 172,826 bytes, SHA256 `4fb7119ee2ca287e4474be48a9589346f7ce303f9f00e254a19009e4dce90c72`. The earlier105 at44b6 is a separate execution, not this run relabelled.

Case17 contains three retained phases, each with a missing-observation negative and observed positive. Scoped host-runner counters assert negative observe/apply0 and positive observe2/apply1. The production entry separately checks refusal and persisted state; its callbacks are not separately instrumented. Six subscenarios are one Alcotest case and are not added to105. This remains controlled fixture/reviewer evidence.

The [type-check failure receipt](main-check-failure.json) and [compiler error excerpt](main-check-three-errors.log) preserve three actual failures: an untyped provider tuple list cannot resolve `OpenAI_compat`; the native-retention test uses an undeclared `Llm_provider` module; three reviewer stubs omit current optional/system-prompt and attempt-continuation labels (the compiler stops at the first). The complete original job log has SHA256 `b2b11cbd96409016cd1149cd3f2462bc32690e4bdf7382e0d5d47c07c78fd751`. This type-only lane runs no test cases.

The repair changes only those three test consumers: give the existing list its canonical provider type, use the existing `Agent_core.Types.Conversation` re-export, and accept the current reviewer labels. Existing fixture rows, callback bodies, assertions, product code, interfaces, and Dune declarations remain unchanged. Parser-only validation passed for all3 files. Repaired-candidate type-checking and test execution have not yet been observed in this record.

File digests are in [manifest.json](manifest.json). Build, source review, type-checking, selected behavior, integration, installation, actual providers, and deployment are separate evidence. No full-regression, installed-runtime, real-model, or deployment success is claimed.
