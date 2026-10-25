# Fusion delivery and judge result counters

Scope: #25913, absorbed #23005's metric outcome compression. Base main `3cce9a517b25863c00b48cfb3dd79b994ebc1044`.

Before this change, delivering a failed synthesis and delivering a successful synthesis both incremented only `outcome=completed`. A skipped judge could not be distinguished in that counter. Existing per-node counters did not supply a row for skipped judges.

The actual compute/project boundaries now record independent `judge_result` alongside delivery `outcome`. The required original deliberation supplies the canonical result and judge node list; policy denials explicitly record not_attempted. Successful canonical answers with failed recorded nodes retain the degradation in synthesized_with_failures. This is observation only; no execution gate or new timeout is introduced.

Five changed OCaml files parse and whitespace passes; the source hashes are in source-checks.json. No local Dune, typecheck or candidate execution has been performed. The selected execution targets are `test/test_fusion_metrics,test/test_fusion_wake`. Full regression is unrun.

Two feature scenarios are defined in the existing wake suite: four computed terminal records flow through actual production project, Board/chat and durable wake, then conflicting replay produces an actual sink error; actual disabled policy compute records a refusal without invoking the panel/judge. These are controlled terminal inputs and not model/provider dispatch proof. Existing metrics tests retain node and refusal-counter checks. No screenshot/UI/runtime/install result is claimed.

The counter counts process-local returned projection attempts, including retries, not unique runs. Exceptions before a sink return and earlier failures remain outside its completion coverage. Seat-level candidate failures, official-client tool gaps, missing usage, latency and full Librarian observability remain separate. This change does not resolve all #25913 requirements and the issue stays open.

Native Stack registration was attempted through gh stack init but refused its global editing lock; unrelated live submit processes were verified. No existing stack, process or lock was altered. Until REST membership confirms otherwise, a published draft is not claimed as a registered Native Stack.

## First selected execution and repair

[Run40161691391](https://github.com/jeong-sik/masc/actions/runs/40161691391) checked out `3d64d9d0327df2d360b444745f3acd381053dbe7` and FAILED at fixture compilation before selected test execution: `Panels_unavailable` expects `skip_reason`, not a string. The test now supplies the existing `No_panel_answers { total = 0 }` constructor, matching its empty prepared panel. Production code is unchanged. Initial SOURCE COMMENT5641477670 missed the blocker and is superseded for compilability. Actual error excerpt is retained; five source hashes refreshed. Repaired-head execution remains unproved.
