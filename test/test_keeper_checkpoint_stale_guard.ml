(** RFC-0225 §3.2: stale OAS checkpoint writes are a disk-SSOT no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_oas_classified] skips a save whose [turn_count] is older
    than the canonical checkpoint observed inside the save transaction, without
    turning that watermark hit into keeper lifecycle failure. *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready
    ~backend:Server_startup_state.Filesystem_backend
  |> Result.get_ok

let temp_dir () =
  let root = Filename.temp_file "test_ckpt_stale_guard_" "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  let session_dir = Filename.concat root "session" in
  Unix.mkdir session_dir 0o755;
  session_dir

let ensure_fs env = Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm (Filename.dirname dir) with _ -> ()

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages = [
    Agent_sdk.Types.{ role = User; content = [Text "hello"]; name = None;
                      tool_call_id = None; metadata = [] };
    Agent_sdk.Types.{ role = Assistant; content = [Text marker]; name = None;
                      tool_call_id = None; metadata = [] };
  ] in
  Agent_sdk.Checkpoint.{
    version = checkpoint_version;
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
    reasoning_effort = None;
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
  match Keeper_checkpoint_store.save_oas_classified ~session_dir ckpt with
  | Ok _ -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)

let test_forward_equal_and_stale () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
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

(* Every decision reloads the canonical disk SSOT; there is no process cache to
   reset or reconstruct after a restart. *)
let test_disk_is_the_watermark_ssot () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-cold" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:8 ~marker:"v8") "seed save";
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
      "forward save from disk SSOT")

(* The OAS per-turn pipeline builds checkpoints with an empty session_id (the
   OAS agent carries no session field). The keeper sink stamps a validated,
   non-empty trace_id before persisting; the store fails loud on an empty
   session_id rather than letting the non-Eio fallback silently write
   "<session_dir>/.json" and drop the checkpoint. *)
let test_empty_session_id_rejected () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:"" ~turn_count:1 ~marker:"empty")
     with
     | Ok _ -> fail "checkpoint store accepted an empty session_id"
     | Error msg ->
       let expected =
         match Keeper_id.Trace_id.of_string "" with
         | Ok _ -> fail "Trace_id parser accepted an empty identifier"
         | Error reason -> reason
       in
       check string "error is the typed trace-id rejection" expected msg);
    (* The silent non-Eio fallback would have written "<session_dir>/.json". *)
    check bool "no orphan .json written for empty session_id" false
      (Sys.file_exists (Filename.concat session_dir ".json"));
    (* A stamped, non-empty session_id persists and round-trips. *)
    save_ok ~session_dir
      (make_checkpoint ~session_id:"trace-1-0000a" ~turn_count:1 ~marker:"stamped")
      "stamped save";
    match Keeper_checkpoint_store.load_oas ~session_dir ~session_id:"trace-1-0000a" with
    | Ok on_disk ->
      check string "round-trips the stamped session_id" "trace-1-0000a"
        on_disk.Agent_sdk.Checkpoint.session_id
    | Error _ -> fail "load after stamped save failed")

let test_invalid_existing_checkpoint_fails_closed () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-corrupt" in
    let path =
      Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id
    in
    let corrupt = "{not-a-checkpoint" in
    Fs_compat.save_file path corrupt;
    (match
       Keeper_checkpoint_store.save_oas_classified
         ~session_dir
         (make_checkpoint ~session_id ~turn_count:9 ~marker:"must-not-write")
     with
     | Error _ -> ()
     | Ok _ -> fail "corrupt existing checkpoint was treated as a cold store");
    check string "corrupt canonical bytes remain untouched" corrupt
      (Fs_compat.load_file path);
    let mismatched =
      make_checkpoint ~session_id:"another-session" ~turn_count:10
        ~marker:"wrong-identity"
      |> Agent_sdk.Checkpoint.to_string
    in
    Fs_compat.save_file path mismatched;
    (match
       Keeper_checkpoint_store.save_oas_classified
         ~session_dir
         (make_checkpoint ~session_id ~turn_count:11 ~marker:"must-not-replace")
     with
     | Error _ -> ()
     | Ok _ -> fail "mismatched checkpoint identity was overwritten");
    check string "mismatched canonical bytes remain untouched" mismatched
      (Fs_compat.load_file path))

let test_multi_domain_writers_leave_max_turn_on_disk () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-domains" in
    save_ok
      ~session_dir
      (make_checkpoint ~session_id ~turn_count:0 ~marker:"seed")
      "seed save";
    let turns = [ 4; 1; 8; 3; 7; 2; 9; 6; 5 ] in
    let writer_count = List.length turns in
    let ready = Atomic.make 0 in
    let start = Atomic.make false in
    let writer turn_count =
      Atomic.incr ready;
      while not (Atomic.get start) do
        Domain.cpu_relax ()
      done;
      Keeper_checkpoint_store.save_oas_classified
        ~session_dir
        (make_checkpoint
           ~session_id
           ~turn_count
           ~marker:(Printf.sprintf "v%d" turn_count))
    in
    let domains = List.map (fun turn -> Domain.spawn (fun () -> writer turn)) turns in
    while Atomic.get ready <> writer_count do
      Domain.cpu_relax ()
    done;
    Atomic.set start true;
    List.iter
      (fun domain ->
        match Domain.join domain with
        | Ok _ -> ()
        | Error error -> fail ("concurrent checkpoint save failed: " ^ error))
      domains;
    let expected = List.fold_left max min_int turns in
    match Keeper_checkpoint_store.load_oas ~session_dir ~session_id with
    | Error _ -> fail "load after concurrent saves failed"
    | Ok checkpoint ->
      check int "canonical disk retains the maximum turn" expected
        checkpoint.Agent_sdk.Checkpoint.turn_count)

let test_ready_runtime_raw_domain_save () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Executor_pool_ref.set (Domain_pool.executor_pool pool);
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let session_id = "raw-domain-ready" in
  let session_dir = Filename.concat base_dir "new-session" in
  let result =
    Domain.spawn (fun () ->
      Keeper_checkpoint_store.save_oas_classified ~session_dir
        (make_checkpoint ~session_id ~turn_count:11 ~marker:"raw-domain"))
    |> Domain.join
  in
  (match result with
   | Ok (Keeper_checkpoint_store.Saved _) -> ()
   | Ok (Keeper_checkpoint_store.Stale_noop _) -> fail "new raw-domain save was stale"
   | Error detail -> fail ("ready-state raw-domain save failed: " ^ detail));
  check bool "save retains create-first session contract" true
    (Sys.file_exists session_dir);
  check bool "stable lock is outside removable session subtree" true
    (Sys.file_exists (session_dir ^ ".checkpoint.lock"));
  match Keeper_checkpoint_store.load_oas ~session_dir ~session_id with
  | Error _ -> fail "raw-domain checkpoint did not round-trip"
  | Ok checkpoint -> check int "raw-domain turn persisted" 11 checkpoint.turn_count

let () =
  run "Keeper_checkpoint_store checkpoint watermark (RFC-0225 §3.2)"
    [
      ( "checkpoint transaction",
        [
          test_case "forward and equal saves pass, stale save is no-op" `Quick
            test_forward_equal_and_stale;
          test_case "canonical disk is the watermark SSOT" `Quick
            test_disk_is_the_watermark_ssot;
          test_case "empty session_id is refused, not silently dropped" `Quick
            test_empty_session_id_rejected;
          test_case "invalid canonical checkpoint fails closed" `Quick
            test_invalid_existing_checkpoint_fails_closed;
          test_case "multi-domain writers leave max turn on disk" `Quick
            test_multi_domain_writers_leave_max_turn_on_disk;
          test_case "ready runtime raw Domain saves through Unix context" `Quick
            test_ready_runtime_raw_domain_save;
        ] );
    ]
