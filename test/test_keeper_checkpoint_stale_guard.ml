(** RFC-0225 §3.2: stale OAS checkpoint writes are no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_oas] now skips a save whose [turn_count]
    is older than the last one saved for the session without turning that
    watermark hit into keeper lifecycle failure. *)

open Alcotest
open Masc

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_ckpt_stale_guard_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages = [
    Agent_sdk.Types.{ role = User; content = [Text "hello"]; name = None;
                      tool_call_id = None; metadata = [] };
    Agent_sdk.Types.{ role = Assistant; content = [Text marker]; name = None;
                      tool_call_id = None; metadata = [] };
  ] in
  Agent_sdk.Checkpoint.{
    version = 4;
    session_id;
    agent_name = "test-agent";
    model = "test-model";
    system_prompt = None;
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count;
    created_at = 1000.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;

    context = Agent_sdk.Context.create_sync ();
    mcp_sessions = [];
    working_context = None;
  }

let save_ok ~session_dir ckpt label =
  match Keeper_checkpoint_store.save_oas ~session_dir ckpt with
  | Ok () -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)

let test_forward_equal_and_stale () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  Keeper_checkpoint_store.For_testing.reset_stale_write_guard ();
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-guard" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"v5") "fresh save";
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:6 ~marker:"v6") "forward save";
    (* Equal turn_count: idempotent re-save (e.g. sanitized retry). *)
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:6 ~marker:"v6b") "equal save";
    (* Stale write must be a nonfatal no-op and must not touch disk. *)
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"v4-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
              { incoming_turn_count; known_turn_count }) ->
       check int "stale incoming turn_count" 4 incoming_turn_count;
       check int "known turn_count is preserved" 6 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "stale save advanced the checkpoint"
     | Error e -> fail ("stale save returned lifecycle failure: " ^ e));
    match Keeper_checkpoint_store.load_oas ~session_dir ~session_id:sid with
    | Ok on_disk ->
      check int "disk keeps the newest turn_count" 6
        on_disk.Agent_sdk.Checkpoint.turn_count
    | Error _ -> fail "load after rejection failed")

(* Cold start: the process-local map is empty but the disk already has a
   newer checkpoint — the guard must backfill from disk and still refuse. *)
let test_cold_start_backfills_from_disk () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  Keeper_checkpoint_store.For_testing.reset_stale_write_guard ();
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-cold" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:8 ~marker:"v8") "seed save";
    (* Simulate a process restart: in-memory knowledge is gone. *)
    Keeper_checkpoint_store.For_testing.reset_stale_write_guard ();
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"v3-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
              { incoming_turn_count; known_turn_count }) ->
       check int "cold stale incoming turn_count" 3 incoming_turn_count;
       check int "cold known turn_count backfilled from disk" 8 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "stale save advanced after cold start"
     | Error e -> fail ("cold stale save returned lifecycle failure: " ^ e));
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:9 ~marker:"v9")
      "forward save after cold start")

let () =
  run "Keeper_checkpoint_store checkpoint watermark (RFC-0225 §3.2)"
    [
      ( "save_oas guard",
        [
          test_case "forward and equal saves pass, stale save is no-op" `Quick
            test_forward_equal_and_stale;
          test_case "cold start backfills last turn_count from disk" `Quick
            test_cold_start_backfills_from_disk;
        ] );
    ]
