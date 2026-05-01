(** IR-3 — checkpoint save error promotion.

    [persist_checkpoint] now returns [(unit, string) result] instead of
    raising.  This test pins:
    1. A successful write returns [Ok ()] and the file exists on disk.
    2. A write to a read-only directory returns [Error _], not an
       exception. *)

open Masc_mcp
open Alcotest

module CP = Oas_worker_exec_checkpoint

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      try Unix.rmdir path with Sys_error _ -> ())
    else
      try Unix.unlink path with Sys_error _ -> ()

let with_tmp_dir f =
  let dir =
    Filename.get_temp_dir_name () ^ "/ir3-test-" ^ string_of_int (Random.int 1000000)
  in
  Fs_compat.mkdir_p dir;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let dummy_checkpoint : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id = "ir3-test";
    agent_name = "test-worker";
    model = "";
    system_prompt = None;
    messages = [];
    usage = Agent_sdk.Types.empty_usage;
    turn_count = 0;
    created_at = 0.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = None;
    context = Agent_sdk.Context.create ();
    mcp_sessions = [];
    working_context = None;
  }

let test_persist_checkpoint_ok () =
  with_tmp_dir (fun dir ->
    let result = CP.persist_checkpoint ~dir ~session_id:"s1" dummy_checkpoint in
    check bool "persist returns Ok" true (Result.is_ok result);
    let path = Filename.concat dir "s1.json" in
    check bool "file exists on disk" true (Sys.file_exists path))

let test_persist_checkpoint_error_on_readonly () =
  let dir =
    Filename.get_temp_dir_name () ^ "/ir3-ro-" ^ string_of_int (Random.int 1000000)
  in
  Fs_compat.mkdir_p dir;
  Unix.chmod dir 0o444;
  let result =
    try CP.persist_checkpoint ~dir ~session_id:"s2" dummy_checkpoint
    with exn ->
      Unix.chmod dir 0o755;
      rm_rf dir;
      failf "persist_checkpoint raised unexpectedly: %s" (Printexc.to_string exn)
  in
  Unix.chmod dir 0o755;
  rm_rf dir;
  check bool "persist returns Error on read-only dir" true (Result.is_error result);
  let err = Result.get_error result in
  check bool "error message mentions session" true
    (try ignore (Str.search_forward (Str.regexp "s2") err 0); true
     with Not_found -> false)

let () =
  run "oas_worker_exec_checkpoint"
    [
      ( "persist_checkpoint",
        [
          test_case "Ok on writable dir" `Quick test_persist_checkpoint_ok;
          test_case "Error on read-only dir (IR-3)"
            `Quick test_persist_checkpoint_error_on_readonly;
        ] );
    ]
