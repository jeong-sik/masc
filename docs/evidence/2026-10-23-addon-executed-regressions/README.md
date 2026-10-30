# Executed Addon regression results and bounded fixture repairs

Source: `25faf14776f1115e962a4c4873e668af386211ad`. These results replace neither historical evidence at other heads nor the original 54 completion criteria.

## Actual selected executions

- [Linux run 39924350904](https://github.com/jeong-sik/masc/actions/runs/39924350904) compiled and executed all five selected suites. Submit-once **9/9**, Curator commit **76/76**, Librarian owner **23/23**, and Librarian durable execution **17/17** passed. Deferred runtime **0/1** failed. Aggregate **125 passed, 1 failed**; the run failed. Full names and observed durations are in [linux-results.json](linux-results.json).
- [Native run 39924354630](https://github.com/jeong-sik/masc/actions/runs/39924354630) compiled matching macOS arm64 server/TUI and executed both selected suites. TUI **24/26**, application **5/5**: aggregate **29 passed, 2 failed**. The run failed and `behavior_passed` is false. [The original receipt](native-receipt.json) preserves both suite exit codes and workflow identity.
- The failed native behavior run still packaged its compiled binaries. Downloaded server, TUI and generated key-reference SHA-256 values match that receipt. The actual server `build-commit` and TUI `--build-commit` commands both returned the selected source. [Artifact identity](artifact-identity.json) proves only these identities. No operator binary was installed and no visible UI was observed.

## Failure causes and source repairs

1. Deferred discovery: denying one Addon export does not remove unrelated deferred composition controls. Cancellation/status can recover existing work. The failed assertion incorrectly required the entire loader to disappear. Its repair exercises the denied exact name, refuses installation and worker RPC, and verifies an independently admitted recovery control remains loadable. No product permission changes are needed.
2. TUI role refresh: the fixture's action schema used top-level `instance_id`; the actual producer/consumer contract requires `context` containing `instance_id` and `incarnation`, plus `request_id` and `action`. The repair uses that envelope and checks the complete original submitted request.
3. Schemaless installation: an exact display-text assertion failed on the Add-ons to Plugins terminology change. Replace display-text comparisons with pending-read retirement, the original manifest request, and explicit catalog/editor decisions. The constitution prohibits new screen wording/layout/row-order tests. This patch replaces the two directly affected wording checks; it does not certify the mixed historical suite as entirely presentation-free.

At the initial source-review boundary, the two fixture patches passed independent source review, parser and diff checks; their repaired tests had not yet executed. The completed selected executions are recorded below. Old failed runs remain failures. Ordinary source approval, native build, test execution, integration, installation and visible use remain separate evidence.

## Remaining original scope

The selected reruns and new artifact identity are now recorded below. The previously merged catalog/Preview stack #45492 is newer than the failed-run source; the old artifact does not prove that stack's UI. The repaired candidate's [bounded native UI observation](native-ui/README.md) now covers A02; G/H both UI, real Agent/provider, recovery, continuity and installation retain their separate criteria. E06 frozen authority repair and durable dispatch/judgment/commit recovery are separate ongoing source work.

## Repaired selected execution and actual downloaded candidate

The two source repairs were executed at exact `a6fba325404c963061b7b95c4c564e35f5ea5e2e`. [Linux39928835869](https://github.com/jeong-sik/masc/actions/runs/39928835869) passed the one previously failing deferred-runtime scenario (**1/1**, 0.200s). [Native39928840589](https://github.com/jeong-sik/masc/actions/runs/39928840589) passed TUI **26/26** (0.026s) and application **5/5** (0.001s), and compiled the matching server/TUI. Both runs completed successfully. The four earlier passing Linux suites were not repeated at this new source; their earlier125-case result retains its original25faf identity.

[Selected results](repaired-selected-results.json), the [unaltered new native receipt](native-repaired-receipt.json), and [actual downloaded identity checks](native-repaired-download.json) preserve source and workflow identities separately. Both downloaded binary digests match the receipt. Their actual server `build-commit` and TUI `--build-commit` commands returned exacta6fba and exit0; generated key-reference digest also matches. This satisfies original A01's selected checks and exact artifact identity. The artifact checks alone did not establish A02; subsequent actual On/Off/reconnect observation, nonempty result preservation and cleanup are recorded [separately](native-ui/README.md). Installation, real Agent/provider execution and the remaining original54 are not completed by these observations. The earlier failed receipts above remain historical evidence and are not rewritten into successes. The doc-only follow-up records this tested candidate; it is not a claim that its own new commit was compiled.
