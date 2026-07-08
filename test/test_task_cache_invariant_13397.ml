(** #13397: Pin the pure [Task_cache_invariant] classifier and verify the
    core invariant logic.

    [is_terminal] must correctly classify all six task status variants.
    [with_fresh_task_status] must return [None] for terminal tasks and
    [Some _] for active tasks, while [fresh_task_status] must read the
    backlog and return the live status. *)

open Alcotest
module T = Masc_domain
module TCI = Task_cache_invariant

(* ============================================================ *)
(* is_terminal — pure, no I/O                                  *)
(* ============================================================ *)

let now = "2026-05-06T00:00:00Z"

let status_done =
  T.Done { assignee = "k1"; completed_at = now; notes = None }

let status_cancelled =
  T.Cancelled { cancelled_at = now; cancelled_by = "operator"; reason = None }

let status_claimed =
  T.Claimed { assignee = "k1"; claimed_at = now }

let status_in_progress =
  T.InProgress { assignee = "k1"; started_at = now }

let status_awaiting =
  T.AwaitingVerification
    { assignee = "k1"
    ; submitted_at = now
    ; verification_id = "req-1"
    ; phase = Awaiting_verifier
    }

let test_is_terminal_done () =
  check bool "Done is terminal" true (TCI.is_terminal status_done)

let test_is_terminal_cancelled () =
  check bool "Cancelled is terminal" true (TCI.is_terminal status_cancelled)

let test_is_terminal_todo () =
  check bool "Todo is not terminal" false (TCI.is_terminal T.Todo)

let test_is_terminal_claimed () =
  check bool "Claimed is not terminal" false (TCI.is_terminal status_claimed)

let test_is_terminal_in_progress () =
  check bool "InProgress is not terminal" false
    (TCI.is_terminal status_in_progress)

let test_is_terminal_awaiting () =
  check bool "AwaitingVerification is not terminal" false
    (TCI.is_terminal status_awaiting)

(* ============================================================ *)
(* with_fresh_task_status — requires a live backlog             *)
(* ============================================================ *)

(** Minimal Eio + temp-dir test harness, borrowed from test_task_dispatch. *)
let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "task_cache_inv_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let config = Masc.Workspace.default_config dir in
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path)
          else Unix.unlink path
      in
      rm dir)
    (fun () -> f config)

let make_task ~id ~status =
  { T.id
  ; title = "test task"
  ; description = "desc"
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = now
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

(** Write a minimal backlog with one task. *)
let seed_backlog config task =
  let backlog : T.backlog =
    { tasks = [ task ]; last_updated = now; version = 1 }
  in
  Workspace_backlog.write_backlog config backlog

let test_fresh_status_done () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-037" ~status:status_done);
    let result = TCI.fresh_task_status config ~task_id:"task-037" in
    check bool "done task status found" true (Option.is_some result);
    check bool "done task is_terminal" true
      (Option.value ~default:T.Todo result |> TCI.is_terminal))

let test_fresh_status_active () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-038" ~status:status_claimed);
    let result = TCI.fresh_task_status config ~task_id:"task-038" in
    check bool "claimed task status found" true (Option.is_some result);
    check bool "claimed task is not terminal" false
      (Option.value ~default:T.Todo result |> TCI.is_terminal))

let test_fresh_status_missing () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-001" ~status:T.Todo);
    let result = TCI.fresh_task_status config ~task_id:"task-999" in
    check bool "absent task returns None" true (Option.is_none result))

let test_with_fresh_terminal_returns_none () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-102" ~status:status_done);
    let result =
      TCI.with_fresh_task_status config
        ~agent_name:"keeper-executor-agent"
        ~task_id:"task-102"
        ~module_name:"test.mention_tracker"
        (fun _ -> `should_not_run)
    in
    check bool "terminal task → None (skip emission)" true
      (Option.is_none result))

let test_with_fresh_active_calls_continuation () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-050" ~status:status_claimed);
    let called = ref false in
    let result =
      TCI.with_fresh_task_status config
        ~agent_name:"keeper-bob-agent"
        ~task_id:"task-050"
        ~module_name:"test.broadcast"
        (fun _status -> called := true; `proceed)
    in
    check bool "active task → continuation called" true !called;
    check bool "active task → Some result" true (Option.is_some result))

(* ============================================================ *)
(* Test runner                                                  *)
(* ============================================================ *)

let () =
  run "task_cache_invariant_13397"
    [ ( "is_terminal"
      , [ test_case "Done is terminal" `Quick test_is_terminal_done
        ; test_case "Cancelled is terminal" `Quick test_is_terminal_cancelled
        ; test_case "Todo is not terminal" `Quick test_is_terminal_todo
        ; test_case "Claimed is not terminal" `Quick test_is_terminal_claimed
        ; test_case "InProgress is not terminal" `Quick
            test_is_terminal_in_progress
        ; test_case "AwaitingVerification is not terminal" `Quick
            test_is_terminal_awaiting
        ] )
    ; ( "fresh_task_status"
      , [ test_case "done task found and terminal" `Quick
            test_fresh_status_done
        ; test_case "claimed task found and non-terminal" `Quick
            test_fresh_status_active
        ; test_case "absent task returns None" `Quick
            test_fresh_status_missing
        ] )
    ; ( "with_fresh_task_status"
      , [ test_case "terminal task returns None (skip)" `Quick
            test_with_fresh_terminal_returns_none
        ; test_case "active task calls continuation" `Quick
            test_with_fresh_active_calls_continuation
        ] )
    ]
