# task-248 verification proof

Commit under test: `5c163eb006 Close execute streams on rejected dispatch`
Branch: `sangsu/task-248-execute-stream-close`

## Required behavior

The execute runtime records a stream start before shell-IR dispatch. Every rejected dispatch branch now calls the same `close_rejected_execute_stream` helper before returning its typed error.

Source: `lib/keeper/keeper_tool_execute_runtime.ml`

The helper maps all four rejection constructors to a stable error label and emits
`Keeper_keepalive_signal.record_execute_stream_end` with an exit status:

```ocaml
let close_execute_stream ~keeper_name ~task_id ~status =
  try
    Keeper_keepalive_signal.record_execute_stream_end
      ~keeper_name
      ~task_id
      ~status
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.warn
      "execute stream end callback failed keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn)
;;

let close_rejected_execute_stream
      ~keeper_name
      ~task_id
      ~(kind : [ `Gate_reject | `Cannot_parse | `Too_complex | `Path_reject ])
      ~detail
  =
  let kind =
    match kind with
    | `Gate_reject -> "gate_reject"
    | `Cannot_parse -> "cannot_parse"
    | `Too_complex -> "too_complex"
    | `Path_reject -> "path_reject"
  in
  close_execute_stream
    ~keeper_name
    ~task_id
    ~status:
      (`Assoc
        [ "kind", `String "exit"
        ; "code", `Int 1
        ; "error", `String kind
        ; "detail", `String detail
        ])
;;
```

The dispatch match contains all four calls, including the complete `Path_reject`
branch:

```ocaml
match dispatch_result with
| Error (Keeper_tooling.Execute_shell_ir.Gate_reject diagnostic) ->
  let detail = message_for_log diagnostic in
  close_rejected_execute_stream
    ~keeper_name:meta.name
    ~task_id
    ~kind:`Gate_reject
    ~detail;
  authorized (typed_error_json diagnostic)
| Error Keeper_tooling.Execute_shell_ir.Cannot_parse ->
  close_rejected_execute_stream
    ~keeper_name:meta.name
    ~task_id
    ~kind:`Cannot_parse
    ~detail:"Cannot parse command";
  authorized (typed_error_json "Cannot parse command")
| Error Keeper_tooling.Execute_shell_ir.Too_complex ->
  close_rejected_execute_stream
    ~keeper_name:meta.name
    ~task_id
    ~kind:`Too_complex
    ~detail:"Command too complex";
  authorized (typed_error_json "Command too complex")
| Error (Keeper_tooling.Execute_shell_ir.Path_reject e) ->
  let detail = message_for_log e in
  close_rejected_execute_stream
    ~keeper_name:meta.name
    ~task_id
    ~kind:`Path_reject
    ~detail;
  authorized
    (typed_error_json
       ~extra_fields:[ "blocked_cmd", `String cmd_for_log ]
       e)
```

The normal `Ok result` path also uses `close_execute_stream`, so stream-end
handling is shared between successful and rejected dispatches.

## Regression test

Source: `test/test_keeper_tool_execute_stream_close.ml`

The test starts a stream, invokes the helper for each rejection kind, asserts
`task_closed`, `closed=true`, the original task id, exit code 1, and the
rejection label. It then appends a later chunk and asserts that its
`task_id` is JSON null, proving the open-stream binding was removed.

The registered cases are exactly:

```ocaml
test_case "Gate_reject" `Quick
  (fun () ->
    test_rejected_dispatch_closes_stream "gate_reject" `Gate_reject)
test_case "Cannot_parse" `Quick
  (fun () ->
    test_rejected_dispatch_closes_stream "cannot_parse" `Cannot_parse)
test_case "Too_complex" `Quick
  (fun () ->
    test_rejected_dispatch_closes_stream "too_complex" `Too_complex)
test_case "Path_reject" `Quick
  (fun () ->
    test_rejected_dispatch_closes_stream "path_reject" `Path_reject)
```

## Verification commands

The local wrapper was run with the existing concurrent Dune lock bypassed
(`MASC_DUNE_THROTTLE=0 MASC_SKIP_OPAM_LOCK=1 MASC_DUNE_ALLOW_BARE_DUNE=1`)
because another worktree held `/tmp/me-dune-local.lock`.

```
bash scripts/dune-local.sh build test/test_keeper_tool_execute_stream_close.exe
```

Result: exit 0.

```
bash scripts/dune-local.sh exec test/test_keeper_tool_execute_stream_close.exe
```

Result: exit 0; `Keeper_tool_execute_stream_close` ran 4 tests:
`Gate_reject`, `Cannot_parse`, `Too_complex`, and `Path_reject`; all
reported `[OK]`, ending with `Test Successful`.

Additional source checks:
- `git status --short --branch` was clean before this proof artifact.
- `git log -1 --oneline` was `5c163eb006 Close execute streams on rejected dispatch`.
- The dispatch source search showed calls at lines 491, 505, 512, and 519, with the
  `Path_reject` call followed by its typed error return.
