# Shared loading optimization observations, 2026-10-20

These packets distinguish the installed server from source and isolated computation probes.
The changes have not been installed or measured through the TUI/browser.

## Prefix encoding buffer

`prefix_buffer_probe.ml` compares the old/new Yojson buffer lifetime on a frozen
82,825,306-byte checkpoint containing 32,494 messages. The input was read locally;
conversation contents and credentials are not included here. Three alternating
runs returned identical SHA256 values. Temporary allocation was 340,689,888 vs
109,518,816 bytes (67.85% lower); elapsed results are in `prefix-buffer-results.txt`.

This probe loads checkpoint message JSON directly, so it measures JSON encoding
and hashing only. It does not execute `Agent_core.Checkpoint.message_to_json`,
range selection, the worker pool, or the whole capture/restore operation.

Run with OCaml 5.5.1 and the installed Yojson/Digestif packages:

```sh
ocamlfind ocamlopt -package yojson,digestif.c,unix -linkpkg prefix_buffer_probe.ml -o /tmp/prefix_buffer_probe
/tmp/prefix_buffer_probe /path/to/frozen-checkpoint.json
```

The source change passed OCaml parsing, `git diff --check`, and an independent
subagent source review with no P0/P1/P2 findings. This is not a GitHub approval.
No local Dune build or CI was run, under the constitution's execution protocol.
The existing `test_librarian_continuity_snapshot` checkpoint-array digest and
restore cases are the integration target; they were not executed this session.
