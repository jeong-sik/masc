(** #13397: [read_fresh_task_status] keeps a task absent from a readable
    backlog apart from a backlog it could not read. *)

open Alcotest
module T = Masc_domain
module TCI = Task_cache_invariant

let now = "2026-05-06T00:00:00Z"

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
  ; execution_links = Masc_domain.no_execution_links
  ; skills = []
  }

(** Write a minimal backlog with one task. *)
let seed_backlog config task =
  let backlog : T.backlog =
    { tasks = [ task ]; task_creation_receipts = []; task_deletion_receipts = []; pending_completion_approvals = []; pending_completion_rejections = []; delivered_completion_rejections = []; last_updated = now; version = 1 }
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
    [ ( "read_fresh_task_status"
      , [ test_case "typed lookup preserves task absence" `Quick
            test_typed_fresh_status_missing
        ; test_case "typed lookup preserves backlog failure" `Quick
            test_typed_fresh_status_unavailable
        ] )
    ]
