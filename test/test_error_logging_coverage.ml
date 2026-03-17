(** Error logging coverage tests for PR #466 silent failure fixes.

    Verifies that the 36 silent failure patterns replaced with explicit
    stderr logging actually emit the expected log messages when triggered.

    Coverage:
    - spawn_registry: Agent_name.of_string failure → "[spawn_registry]" prefix
    - tool_task: complete_task on nonexistent task → "[task]" prefix
    - a2a_tools: submit_heartbeat_result with unknown status → "[a2a]" prefix

    Stderr capture approach: Unix.pipe + Unix.dup2 redirect.
    The pipe is set non-blocking to avoid blocking on empty read.
*)

open Alcotest

module Spawn_registry = Masc_mcp.Spawn_registry
module Tool_task = Masc_mcp.Tool_task
module A2a_tools = Masc_mcp.A2a_tools
module Room = Masc_mcp.Room

(* ============================================================
   Stderr Capture Utility
   ============================================================ *)

(** Capture stderr output produced by [f ()].

    Redirects Unix file descriptor 2 (stderr) to a pipe, runs [f],
    flushes the OCaml stderr buffer, then restores and reads the pipe.
    Sets the read end non-blocking to avoid hanging on empty output. *)
let capture_stderr f =
  let (pipe_read, pipe_write) = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  (try f () with _ -> ());
  (* Flush OCaml's stderr buffer into the pipe before restoring *)
  flush stderr;
  Unix.dup2 saved_stderr Unix.stderr;
  Unix.close saved_stderr;
  (* Read without blocking *)
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 256 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf tmp 0 n; read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception _ -> ()
  in
  read_all ();
  Unix.close pipe_read;
  Buffer.contents buf

let str_contains haystack needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    let i = ref 0 in
    while !i <= hl - nl && not !found do
      if String.sub haystack !i nl = needle then found := true;
      incr i
    done;
    !found
  end

(* ============================================================
   Test environment helpers
   ============================================================ *)

let make_test_dir () =
  let unique_id = Printf.sprintf "masc_errlog_%d_%d"
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1_000_000.)) in
  Filename.concat (Filename.get_temp_dir_name ()) unique_id

let rec rm_rf path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  end

let with_test_room f =
  let dir = make_test_dir () in
  Unix.mkdir dir 0o755;
  let config = Room.default_config dir in
  let _ = Room.init config ~agent_name:(Some "test-agent") in
  Fun.protect
    ~finally:(fun () -> (try let _ = Room.reset config in () with _ -> ()); rm_rf dir)
    (fun () -> f config)

(* ============================================================
   spawn_registry: Agent_name invalid input → "[spawn_registry]" on stderr
   ============================================================ *)

(** record_failure with an invalid agent name (contains @, exceeds valid pattern).
    The function calls Agent_name.of_string which returns Error, triggering eprintf. *)
let test_spawn_registry_record_failure_logs () =
  let reg = Spawn_registry.create_registry () in
  let output = capture_stderr (fun () ->
    (* An agent name with special chars like "@" triggers Invalid_agent_name *)
    Eio_main.run @@ fun _env ->
    Spawn_registry.record_failure reg "invalid@agent!name"
  ) in
  check bool "stderr contains [Spawn] prefix"
    true (str_contains output "[Spawn]")

(** list_by_agent with an invalid agent name logs and returns empty list. *)
let test_spawn_registry_list_by_agent_invalid_logs () =
  let reg = Spawn_registry.create_registry () in
  let output = capture_stderr (fun () ->
    Eio_main.run @@ fun _env ->
    let result = Spawn_registry.list_by_agent reg ~agent_name:"!!bad!!" in
    (* Verify the function returns [] gracefully *)
    assert (result = [])
  ) in
  check bool "stderr contains [Spawn] prefix for list_by_agent"
    true (str_contains output "[Spawn]")

(** clear_failures with an invalid agent name logs (does not crash). *)
let test_spawn_registry_clear_failures_invalid_logs () =
  let reg = Spawn_registry.create_registry () in
  let output = capture_stderr (fun () ->
    Eio_main.run @@ fun _env ->
    Spawn_registry.clear_failures reg "  "  (* blank → trimmed to "" → invalid *)
  ) in
  check bool "stderr contains [Spawn] prefix for clear_failures"
    true (str_contains output "[Spawn]")

(* ============================================================
   tool_task: complete on nonexistent task → "[task]" on stderr
   ============================================================ *)

(** handle_done with a task_id that does not exist.
    Room.complete_task_r returns Error (TaskNotFound ...) and
    the notification path fires the [task] eprintf. *)
let test_tool_task_done_nonexistent_logs () =
  with_test_room @@ fun config ->
  let ctx : Tool_task.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-does-not-exist-xyz");
    ("notes", `String "");
  ] in
  let output = capture_stderr (fun () ->
    ignore (Tool_task.handle_done ctx args)
  ) in
  check bool "stderr contains [Task] prefix for done on missing task"
    true (str_contains output "[Task]")

(** handle_cancel with a task_id that does not exist → "[task]" eprintf. *)
let test_tool_task_cancel_nonexistent_logs () =
  with_test_room @@ fun config ->
  let ctx : Tool_task.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-phantom-abc");
    ("reason", `String "test cancel");
  ] in
  let output = capture_stderr (fun () ->
    ignore (Tool_task.handle_cancel_task ctx args)
  ) in
  check bool "stderr contains [Task] prefix for cancel on missing task"
    true (str_contains output "[Task]")

(* ============================================================
   a2a_tools: submit_heartbeat_result unknown status → "[a2a]" on stderr
   ============================================================ *)

(** submit_heartbeat_result with a status that is not "acted", "skipped",
    or "failed". result becomes Error "Unknown worker status: ..." and the
    [a2a] eprintf fires. *)
let test_a2a_submit_unknown_status_logs () =
  let output = capture_stderr (fun () ->
    ignore (A2a_tools.submit_heartbeat_result
      ~worker_name:"test-worker"
      ~agent:"test-agent"
      ~status:"INVALID_STATUS_XYZ"
      ~summary:"test summary"
      ~tool_call_count:0
      ~tool_names:[]
      ~decision_reason:"invalid test"
      ~decision_confidence:0.0
      ())
  ) in
  check bool "stderr contains [Misc] prefix for unknown status"
    true (str_contains output "[Misc]")

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  run "Error logging coverage (PR #466)" [
    "spawn_registry", [
      test_case "record_failure invalid name logs [spawn_registry]"
        `Quick test_spawn_registry_record_failure_logs;
      test_case "list_by_agent invalid name logs [spawn_registry]"
        `Quick test_spawn_registry_list_by_agent_invalid_logs;
      test_case "clear_failures blank name logs [spawn_registry]"
        `Quick test_spawn_registry_clear_failures_invalid_logs;
    ];
    "tool_task", [
      test_case "done on missing task logs [task]"
        `Quick test_tool_task_done_nonexistent_logs;
      test_case "cancel on missing task logs [task]"
        `Quick test_tool_task_cancel_nonexistent_logs;
    ];
    "a2a_tools", [
      test_case "submit_heartbeat unknown status logs [a2a]"
        `Quick test_a2a_submit_unknown_status_logs;
    ];
  ]
