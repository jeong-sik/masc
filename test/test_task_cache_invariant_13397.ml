(** #13397: Pin the pure [Task_cache_invariant] classifier and the canonical
    backlog lookup.

    [is_terminal] must correctly classify all six task status variants, and
    [read_fresh_task_status] must keep an absent task apart from a backlog it
    could not read. *)

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
    ; started_at = now
    ; submitted_at = now
    ; intent = Complete_task
    ; verification_id = "req-1"
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
(* read_fresh_task_status — requires a live backlog             *)
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
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }

(** Write a minimal backlog with one task. *)
let seed_backlog config task =
  let backlog : T.backlog =
    { tasks = [ task ]; last_updated = now; version = 1 }
  in
  Workspace_backlog.write_backlog config backlog

let test_typed_fresh_status_missing () =
  with_temp_config (fun config ->
    let _ = Masc.Workspace.init config ~agent_name:(Some "tester") in
    seed_backlog config (make_task ~id:"task-001" ~status:T.Todo);
    match TCI.read_fresh_task_status config ~task_id:"task-999" with
    | TCI.Absent -> ()
    | TCI.Found _ -> fail "absent task was reported as found"
    | TCI.Unavailable detail ->
      failf "readable backlog was reported unavailable: %s" detail)

let test_typed_fresh_status_unavailable () =
  with_temp_config (fun config ->
    match TCI.read_fresh_task_status config ~task_id:"task-999" with
    | TCI.Unavailable _ -> ()
    | TCI.Absent -> fail "missing backlog was collapsed into task absence"
    | TCI.Found _ -> fail "missing backlog unexpectedly returned a task")

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
    ; ( "read_fresh_task_status"
      , [ test_case "typed lookup preserves task absence" `Quick
            test_typed_fresh_status_missing
        ; test_case "typed lookup preserves backlog failure" `Quick
            test_typed_fresh_status_unavailable
        ] )
    ]
