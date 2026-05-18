# Shell Gate Baseline Corpus

Phase 0 of the Shell IR Promotion Goal Plan (`Shell IR Promotion Goal
Plan - 2026-05-18.html`, PR-A).

Each row in `baseline.jsonl` is one fixture used by
`test_exec_shell_command_gate.ml` to pin both:

- The legacy `Worker_dev_tools.validate_command_coding_with_allowlist`
  verdict (`legacy_verdict`).
- The Phase 1 SSOT `Masc_exec_command_gate.Shell_command_gate.gate`
  verdict (`ir_verdict`).

Recording both before any code change lets later PRs (Phase 2..7)
diff against this baseline and show that a change is intentional —
not an accidental policy drift.

## JSONL schema

Each line is a single object:

```
{
  "raw_cmd": "<the input string>",
  "category": "<corpus category>",
  "expected_legacy_verdict": "<ok | injection | chain_or_redirect | ...>",
  "expected_ir_verdict": "<allow | reject | cannot_parse | too_complex>",
  "ir_detail": "<optional tag — reject_reason, parse_reason, or too_complex_reason>",
  "note": "<one-line rationale>"
}
```

`category` is one of:

- `successful` — legacy and IR both allow.
- `rejected` — legacy and IR both reject (or both classify outside
  the allowlist) for the same root reason.
- `false_positive` — legacy rejects a benign command that IR
  correctly allows. This is the bucket the quoted-pipe regex fix
  (#16110) and follow-ups continue to drain.
- `too_complex` — IR classifies as `too_complex` (heredoc, cmd_subst,
  proc_subst, logic_op, …); legacy may allow or reject depending on
  metachar scan.
- `quoted_pipe`, `regex_alternation`, `literal_pipe`, `real_pipeline`,
  `redirection`, `glob`, `path_traversal` — feature buckets for the
  Plan's "Phase 0 minimum set".

## Legacy verdict tags

`block_reason_to_string` cases map to short tags here:

- `ok` — `validate_command_coding_with_allowlist` returned `Ok ()`.
- `empty_command` — `Error Empty_command`.
- `chain_or_redirect` — `Error Chain_or_redirect`.
- `injection` — `Error Injection`.
- `process_substitution` — `Error Process_substitution`.
- `unsafe_redirect` — `Error Unsafe_redirect`.
- `pipes_not_allowed` — `Error Pipes_not_allowed`.
- `command_not_allowed` — `Error (Command_not_allowed _)`.

## IR verdict tags

`Shell_command_gate.verdict_tag` produces these:

- `allow`, `reject`, `cannot_parse`, `too_complex`.

`ir_detail` carries the sub-reason tag:

- For `reject`: see `reject_reason_tag` —
  `command_not_in_allowlist` / `pipeline_segment_disallowed` /
  `pipes_not_allowed` / `path_outside_policy`.
- For `cannot_parse`: see `parse_reason_tag` — `parse_error` /
  `timeout` / `depth_limit` / `token_limit`.
- For `too_complex`: see `too_complex_reason_tag` —
  `unsupported_nested_pipeline` / `heredoc` / `cmd_subst` /
  `proc_subst` / `subshell` / `logic_op` / `redirect` / `glob_brace`
  / `background` / etc.

## Updating the corpus

If a fixture's expectation changes intentionally (e.g. Phase 3
flips authority and a `false_positive` row becomes a `successful`
row), update the JSONL and reference the PR/RFC in the
commit. Mechanical drift is what this corpus is built to detect —
do not "fix" rows without an explicit reason.

Allowlist used for the IR verdict in tests:
`[ "rg"; "sort"; "head"; "wc"; "cat"; "git"; "ls"; "grep" ]`
(superset of the categories needed to differentiate
`command_not_in_allowlist` from `cannot_parse` for the rejection
fixtures).
