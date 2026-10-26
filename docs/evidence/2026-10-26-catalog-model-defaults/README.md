# Catalog model defaults — #27898

The active Runtime_agent → Runtime_transport → Runtime_transport_label_resolution → Runtime_model_string path previously reclassified labels through Provider_registry and inferred auto models from derived environment keys, supported-model lists, discovery or synthetic auto labels. Classification now selects an AGENT_CORE Provider_runtime_binding and passes that same immutable value into to_provider_config. Aliases carry its canonical provider ID. auto passes model omission to AGENT_CORE resolve_model, which accepts only that binding's explicit default_model; missing defaults refuse execution.

The config construction boundary preserves explicit credentials and per-call temperature, output tokens, system prompt, keep-alive and context options. Provider/model context is resolved through the resulting provider config. Request preparation still owns policy freezing. This change does not claim all catalog/manifest state is immutable or collapse every credential/auth surface.

Default execution projection emits explicit operator choices and concrete available catalog defaults. It no longer derives provider-specific default environment keys, chooses the first supported model, invents auto, or discovers an anonymous local candidate. An incomplete or present-but-blank explicit configuration returns no candidates. Only absence permits the catalog fallback. A review found that trimming environment presence too early violated this boundary; the final source fixes that and exercises blank/whitespace controls.

## Verification boundaries

- File → interface → consumer → target: runtime classifier/resolve/config construction → selected binding/default model → active Runtime_transport → test/test_runtime_model_label_binding. Fifteen cases include parent provider/policy/custom URL controls and five catalog-default scenarios. No HTTP is sent.
- Projection/auth availability → Keeper/Dashboard execution candidate consumers → test/test_runtime_model_label_binding plus test/test_runtime_binding_auth_available (four existing auth cases).
- Baseline b34446e31ae73575706c8078cd859e30af82e618, run40206295626: actual15, existing10 PASS/new5 FAIL. Failures cover missing default, derived environment precedence, alias rejection, supported-model inference and projection. Assertions after each failure were not reached.
- Intermediate 1e6a019a16bfd6bd0621c0d303872a5da008968b, run40206442824: SUCCESS19, model-label15 + auth4. This predates added blank-value and per-call option assertions; it does not certify them.
- Final source935349f22b821d6f23e2212ad787876cfad00e91, run40206871608: dispatched for the same two suites; actual outcome will be recorded separately.

Changed OCaml syntax parsing and whitespace checks pass. Source hashes and selected logs retain source/result ownership and raw log SHA/byte counts. No local Dune build, full regression, live provider request, installed runtime, rendered UI, deployment, merge or whole-issue completion is claimed.

Two independent reviewers gave SOURCE PASS at935349f22b821d6f23e2212ad787876cfad00e91/basefc7092b8a97b3d825ebe78d5ec0d15f7b7b1ea2b/diff74ee5c5b88fccca5ec4825e153d9b88f93f503e7429e36071d4f07b3e35f4204 after the P2 blank-config repair. These are source assessments, not formal GitHub approvals. PR45993 depends on45987. Native stack submission reports repository disabled and REST stack:null; do not infer native membership from the branch chain.

The original #27898 hard-cut checklist remains open: immutable catalog/registry/manifest consolidation and complete one-time binding across remaining callers are not established by this bounded high-level repair.

## Actual final execution

[Final run40206871608](https://github.com/jeong-sik/masc/actions/runs/40206871608) completed SUCCESS at exact935349f22b821d6f23e2212ad787876cfad00e91: **19 actual cases PASS** (15 model-label binding +4 runtime-binding auth). New blank/whitespace explicit-configuration controls, incomplete/blank pair rejection and all explicit call-option preservation assertions were reached. This supersedes the earlier pending observation; intermediate19 is not added to final19. The evidence-only follow-up preserves all14 source hashes. Retained log lines have trailing whitespace removed; their digest/byte count describes the complete original raw log.
