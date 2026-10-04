# v0.49.0 lane-editor fixture repair

## Failure

Completed [Full RC37137607438](https://github.com/jeong-sik/masc/actions/runs/37137607438) tested fd7e6c37e006af09b1dba65fb2b3b55249104c7f and failed compile and behavior; all installation jobs succeeded. Its test-suite-log artifact11280481125 has SHA-25668852387b201be11ef1cfb8fa24742103833b7419aaff90d3382b00a1303d3d9.

The Lanes footer expected providers although the current binding opens models. Two parser rejection assertions omitted the supported replace action and first direction. The parser also lacked the comma between drop and move. Existing rejection checks remain exact.

The native PTY replacement scenario failed waiting for gpt-6-luna medium to redraw after filtering: first emitted offset24628, wait started25685. The selected row stays unchanged; only the filter redraws. An initial diagnostic reproduced that failure. Fixing the first barrier exposed a partial tall-resize frame and clipped context labels, then an Escape wait on the unchanged Model order title. The final fixture waits for actual changes and complete frames, and checks all eight fixture model labels, selected runtime and picker dismissal.

## Diagnostic execution

The final focused run_replace_and_promote invocation passed using the RC's existing macOS ARM64 binary, commitfd7e6c37e006af09b1dba65fb2b3b55249104c7f, SHA-256f3531778d03b6b2bfd68ae86ba47507cb653bcffd62cd543b2720c4e918b882d. The Python test SHA-256 is7494323b657d7b45bacfd33b45152147456c2ea65fc09dccd92a489df6771eda.

The saved posts show exactly the replacement of account.current with account.luna-medium, followed by promotion of that replacement to first. Original exact POST and slot-order assertions passed. All eight expanded candidate labels and picker dismissal passed. The final PTY capture SHA-256 is49c21679d7f7ce8d9ad2cbe03c10d2ef1d1d8f8dbfee254173f73f62f80eec1c; the temporary raw capture is not committed because it includes repetitive terminal control output. The manifest, resulting screen, requests and runner output are retained here.

OCaml syntax parsing for all three changed modules, Python AST parsing and git diff --check passed. Independent rc_pty_review and release_merge_review source reviews found no P0-P2 finding in the four-file delta.

## Scope

This is an existing native binary with the repaired fixture script, not a binary built from this PR, a full runtime-lane suite run, or a successful final candidate RC. The native OCaml suites and integrated Linux behavior remain for the final same-head Full RC. PDF inspection is a separate unresolved failure tracked by #41029.
