# PR #41097 release-base conflict reconciliation

The PR head before reconciliation was
`2a38c39b4283c3f8eada42e1ac4d339752061153`. Its original fork point was
`234c79ed95a51492497608c7eed64a1f060c17af`. The target branch remains
`release/v049-frozen-base-1123`, now at
`3b34c90527a99b6c72dca8eae35fe6bf1bd8806f`; this is not a main integration.
REST reported no native stack membership for #41097.

The release branch already integrated the original refused-input repair through
#41099, then incorporated later fixes through #41103, #41101 and #41133.
Four files conflicted when bringing that target into the older PR branch:
`bin/masc_tui.ml`, `bin/masc_tui_types.ml`,
`test/test_tui_chat_queue_wiring.ml`, and
`test/test_tui_remote_workspace_history_pty.py`.

The resolution preserves the complete current release versions. In particular:

- Queue submission ordinals and input-retention behavior from the original PR
  remain present; both queue implementation and interface already matched the
  release base byte-for-byte before reconciliation.
- Resume reads the current roster for the expected workspace, preserves local
  input holds during that read, and rechecks control generation. A cached active
  Keeper row cannot bypass a newer server pause.
- Successful current resume completion releases and launches retained input in
  order. Failed authority reads leave it retained and retryable.
- The paused-before-resume PTY scenario, explicit identity-transition barriers,
  restored-composer checks, broken-pipe handling and release FIFO watchdog
  correction are retained.

`changelog.d/41097.md` is removed because #41099 already folded the same change
into the v0.49.0 section of `CHANGELOG.md`.

Before adding this evidence file, the resolved index tree was identical to the
current target tree. Consequently this PR's final diff against that target is
only this evidence file; it introduces no additional product-code change.
Six relevant OCaml implementations/interfaces passed parse-only checks; two
relevant Python files passed AST parsing. All eight checked files match the
current release base exactly, and diff whitespace checks passed.

No local Dune build, typecheck, native/PTY execution, new CI run, release approval,
merge, deployment or tag publication is claimed. Earlier failed/full release
runs do not certify this reconciled head. Any release publication still needs
its own exact-head Full RC and independent approval.
