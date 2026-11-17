# Document followup: result boundaries

[Results](results.json) records the 2026-11-17 work-boundary reads of the named GitHub runs, jobs and PRs. Original Actions logs supplied the actual checkout commits. The retained JSON is a selected derivative, not a copy of those logs; `log_content_sha256` identifies their original decoded content. Linked jobs provide the source.

Three `PR type-check (dune build @check)` jobs ran successfully on the recorded synthetic merge objects. Two Schedule jobs were skipped although their workflows succeeded. These are neither behavior-suite results nor checks of a later Gemini followup.

The [Keeper comment](https://github.com/jeong-sik/masc/pull/52620#issuecomment-6935761315) and original operation `kmsg-2a3760bb349072a26f5374a5cd9c84b9` report the two maintained suites at exact parent 4ccdd508: 12 and 51 cases, zero failures and skips. Actual compiler was 5.5.1. Build logs m1/m2 arrived and match their declared byte lengths and full SHA-256. The first r1 transfer decodes to 1,173 bytes instead of the declared 1,174 and has a different hash; r2 bytes have not arrived. Original preserved-file transfer was requested again without rerunning tests. These incomplete transfers do not establish direct verification of either execution log. This is explicitly reported execution evidence, not a 5.5.2 result or a new Gemini test result.

Gemini followup b88ffb072fde moves document admission into `Backend_gemini.project_history`, preserves canonical documents and existing signature checks, and extends an existing registered test case with four Gemini combinations. Four full changed OCaml files parse on 5.5.2 and an independent reviewer read the delta. Those checks do not execute the new combinations. Shared elapsed-deadline removal did not make the projector immutable: its walk-owned mutable memo remains.

All three Schedule members were separately observed merged. Their merge commits differ from their CI checkout objects. The shared GitHub login does not identify the session that marked them Ready or initiated integration. This author performed neither action.

This record does not establish external media-reader support, real PDF/STT/provider execution, deployment, restart recovery or the original multi-Keeper Farm success conditions.
