(** RFC-0225 §3.2: stale AGENT_CORE checkpoint writes are a disk-SSOT no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_agent_core_classified] skips a save whose [turn_count] is older
    than the canonical checkpoint observed inside the save transaction, without
    turning that watermark hit into keeper lifecycle failure.

    The canonical file is parsed under the stable session lock for every
    admission decision. No process-local cache, fingerprint, or sidecar may
    substitute for the checkpoint bytes. The canonical file is written in
    compact JSON. *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready ()
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
    Agent_core.Types.{ role = User; content = [Text "hello"]; name = None;
                      tool_call_id = None; metadata = [] };
    Agent_core.Types.{ role = Assistant; content = [Text marker]; name = None;
                      tool_call_id = None; metadata = [] };
  ] in
  Agent_core.Checkpoint.{
    version = checkpoint_version;
    session_id;
    agent_name = "test-agent";
    model = "test-model";
    system_prompt = None;
    messages;
    usage = Agent_core.Types.empty_usage;
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
    response_format = Agent_core.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;

    context = Agent_core.Context.create_sync ();
    mcp_sessions = [];
    working_context = None;
  }

let save_ok ~session_dir ckpt label =
  match Keeper_checkpoint_store.save_agent_core_classified ~session_dir ckpt with
  | Ok _ -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)

(* Three writers reach this store. Only one ran the structural check first --
   the mid-run sink and finalize assemble a checkpoint directly and called the
   store straight -- so a history with an orphan tool result was admitted by
   the two hottest paths and reloaded later (#25561). The check now lives at
   the boundary all three pass through. *)
let checkpoint_with_orphan_tool_result ~session_id =
  let messages =
    [ Agent_core.Types.
        { role = User
        ; content = [ Text "hello" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      (* A result for a tool call that was never requested. *)
    ; Agent_core.Types.
        { role = Tool
        ; content = [ ToolResult { tool_use_id = "tu-never-requested"; content = "x"; outcome = Tool_succeeded; json = None; content_blocks = None } ]
        ; name = None
        ; tool_call_id = Some "tu-never-requested"
        ; metadata = []
        }
    ]
  in
  { (make_checkpoint ~session_id ~turn_count:1 ~marker:"orphan") with
    Agent_core.Checkpoint.messages
  }
;;

let test_structurally_invalid_checkpoint_is_refused_at_the_store () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "structural-guard" in
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~session_dir
      (checkpoint_with_orphan_tool_result ~session_id:sid)
  with
  | Ok _ -> fail "a checkpoint with an orphan tool result must not be saved"
  | Error message ->
    check
      bool
      "the refusal names the structural contract"
      true
      (let needle = "structurally invalid" in
       let n = String.length needle in
       let rec at i =
         i + n <= String.length message
         && (String.equal (String.sub message i n) needle || at (i + 1))
       in
       at 0);
    (* Nothing was written: a refused checkpoint must not leave a partial file
       the next load would read. *)
    let path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
    in
    check bool "no checkpoint file was created" false (Sys.file_exists path)
;;

(* #31677: a provider-authored tool_use input with a duplicate object key
   survives parsing (Yojson keeps both entries) and then refuses canonical
   encoding at the sink. Before the recovery copy, that refusal repeated at
   the same stage of every later turn — one degenerate generation bricked
   the keeper until restart. *)
let checkpoint_with_unencodable_tool_use ~session_id =
  let messages =
    [ Agent_core.Types.
        { role = User
        ; content = [ Text "run it" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
    ; Agent_core.Types.
        { role = Assistant
        ; content =
            [ ToolUse
                { id = "call-1"
                ; name = "Execute"
                ; input = `Assoc [ ("cmd", `String "a"); ("cmd", `String "b") ]
                }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
    ]
  in
  { (make_checkpoint ~session_id ~turn_count:1 ~marker:"poisoned") with
    Agent_core.Checkpoint.messages
  }
;;

let test_unencodable_payload_is_recovered_at_the_sink () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "sink-recovery" in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~session_dir
      (checkpoint_with_unencodable_tool_use ~session_id:sid)
  with
  | Error message -> fail ("the sink should have stored the recovery copy: " ^ message)
  | Ok _ ->
    check bool "the recovery copy was written" true (Sys.file_exists path);
    let bytes = Fs_compat.load_file path in
    (match Agent_core.Checkpoint.of_string bytes with
     | Ok loaded ->
       (* The call itself survives; only the unencodable args became empty. *)
       (match loaded.Agent_core.Checkpoint.messages with
        | _ :: { Agent_core.Types.content = [ ToolUse { id; input; _ } ]; _ } :: _ ->
          check string "the tool call id survives" "call-1" id;
          check bool "the duplicate-key input became an empty object" true
            (input = `Assoc [])
        | messages -> failf "expected the poisoned assistant message, got %d" (List.length messages))
     | Error error ->
       fail ("the stored recovery copy must decode: " ^ Agent_core.Error.to_string error))
;;

let test_valid_checkpoint_still_saves () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "structural-guard-ok" in
  save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"ok") "valid save";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  check bool "a valid checkpoint is written" true (Sys.file_exists path)
;;

let test_run_context_binds_generation_before_agent_core_checkpoint () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> cleanup_dir base_dir);
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String "generation-context" ])
    with
    | Ok meta -> meta
    | Error detail -> fail ("meta fixture failed: " ^ detail)
  in
  let shared_context = Agent_core.Context.create () in
  let run_context =
    Keeper_run_context.prepare_run_context
      ~config:(Workspace.default_config base_dir)
      ~meta
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~base_dir
      ~runtime_id:"unconfigured-test-runtime"
      ~shared_context
      ()
  in
  check bool "caller-owned context remains the AGENT_CORE context" true
    (run_context.shared_context == shared_context);
  let agent =
    Agent_core.Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~context:run_context.shared_context
      ()
  in
  let (_ : Agent_core.Checkpoint.t) = Agent_core.Agent.checkpoint agent in
  ()

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
       Keeper_checkpoint_store.save_agent_core_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"v4-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
              { incoming_turn_count; known_turn_count }) ->
       check int "stale incoming turn_count" 4 incoming_turn_count;
       check int "known turn_count is preserved" 6 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "stale save advanced the checkpoint"
     | Error e -> fail ("stale save returned lifecycle failure: " ^ e));
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
    | Ok on_disk ->
      check int "disk keeps the newest turn_count" 6
        on_disk.Agent_core.Checkpoint.turn_count
    | Error _ -> fail "load after rejection failed")

(* The canonical checkpoint file is the only durable admission watermark
   (RFC-0225 §3.2). *)
let test_disk_is_the_watermark_ssot () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-cold" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:8 ~marker:"v8") "seed save";
    (match
       Keeper_checkpoint_store.save_agent_core_classified ~session_dir
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

let test_externally_replaced_canonical_is_the_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-external-write" in
    let canonical_path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id
    in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:5 ~marker:"v5")
      "seed save";
    Fs_compat.save_file canonical_path
      (make_checkpoint ~session_id ~turn_count:9 ~marker:"external-v9"
       |> Agent_core.Checkpoint.to_string);
    match
      Keeper_checkpoint_store.save_agent_core_classified ~session_dir
        (make_checkpoint ~session_id ~turn_count:7 ~marker:"stale-v7")
    with
    | Ok
        (Keeper_checkpoint_store.Stale_noop
           { incoming_turn_count; known_turn_count }) ->
      check int "external replacement makes turn 7 stale" 7 incoming_turn_count;
      check int "canonical replacement is the known watermark" 9 known_turn_count
    | Ok (Keeper_checkpoint_store.Saved _) ->
      fail "stale save ignored an externally replaced canonical checkpoint"
    | Error error -> fail ("external replacement classification failed: " ^ error))

(* The AGENT_CORE per-turn pipeline builds checkpoints with an empty session_id (the
   AGENT_CORE agent carries no session field). The keeper sink stamps a validated,
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
       Keeper_checkpoint_store.save_agent_core_classified ~session_dir
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
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:"trace-1-0000a" with
    | Ok on_disk ->
      check string "round-trips the stamped session_id" "trace-1-0000a"
        on_disk.Agent_core.Checkpoint.session_id
    | Error _ -> fail "load after stamped save failed")

(* Issue #25077 item 1: [canonical_session_location] is the containment
   boundary shared by the lock file, the history archive, and every
   checkpoint path. A leaf that is not one real path segment (".." / ".")
   must be refused before any filesystem side effect, and a symlink leaf
   must be refused before the lock is derived: either would relocate
   lock/checkpoint writes outside the session root that the
   [Keeper_fs] ownership containment protects on the write chain. *)
let test_session_leaf_containment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  let base = Filename.dirname session_dir in
  let target = Filename.concat base "elsewhere" in
  let link = Filename.concat base "session-link" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      cleanup_dir target;
      cleanup_dir session_dir)
    (fun () ->
      let reject label dir =
        match
          Keeper_checkpoint_store.with_session_lock ~session_dir:dir
            (fun _ -> ())
        with
        | Ok () -> fail (label ^ ": escaping session_dir was accepted")
        | Error _ -> ()
      in
      (* Exact typed rejection for the ".." leaf pins the boundary error. *)
      (match
         Keeper_checkpoint_store.with_session_lock
           ~session_dir:(Filename.concat base Filename.parent_dir_name)
           (fun _ -> ())
       with
       | Ok () -> fail "'..' leaf: escaping session_dir was accepted"
       | Error msg ->
         check string "'..' leaf is the typed leaf rejection"
           (Printf.sprintf
              "checkpoint session directory rejected: leaf %S of %S is not \
               a real path segment"
              Filename.parent_dir_name
              (Filename.concat base Filename.parent_dir_name))
           msg);
      reject "'.' leaf" (Filename.concat base Filename.current_dir_name);
      reject "NUL leaf" (Filename.concat base "abc\000def");
      (* A symlink leaf would redirect every checkpoint and lock write
         through its target. *)
      Unix.mkdir target 0o755;
      Unix.symlink target link;
      reject "symlink leaf" link;
      (* The genuine session directory still passes the same boundary. *)
      match
        Keeper_checkpoint_store.with_session_lock ~session_dir (fun _ -> ())
      with
      | Ok () -> ()
      | Error e -> fail ("real session leaf rejected: " ^ e))

(* Issue #25077: history snapshot ids arrive verbatim from the dashboard
   HTTP surface. A non-segment id must never reach the filesystem — delete
   reports it [missing], load reports [Not_found] — and a file outside the
   session directory must stay unreachable through either entry point. *)
let test_history_snapshot_id_containment () =
  let session_dir = temp_dir () in
  let outside = Filename.concat (Filename.dirname session_dir) "victim.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink outside with Unix.Unix_error _ -> ());
      cleanup_dir session_dir)
    (fun () ->
      Fs_compat.save_file outside "outside-session";
      let escape = "../victim.json" in
      (match
         Keeper_checkpoint_store.delete_agent_core_history_files ~session_dir
           ~snapshot_ids:[ escape ]
       with
       | [], [ missing ] ->
         check string "escaping id is reported missing" escape missing
       | deleted, missing ->
         fail
           (Printf.sprintf "unexpected delete outcome: deleted=%d missing=%d"
              (List.length deleted) (List.length missing)));
      check bool "file outside the session dir survives" true
        (Sys.file_exists outside);
      match
        Keeper_checkpoint_store.load_agent_core_history_file ~session_dir
          ~snapshot_id:escape
      with
      | Error Keeper_checkpoint_store.Not_found -> ()
      | Ok _ -> fail "escaping snapshot_id load succeeded"
      | Error _ ->
        fail "escaping snapshot_id load returned a non-Not_found error")

let test_invalid_existing_checkpoint_fails_closed () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-corrupt" in
    let path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id
    in
    let corrupt = "{not-a-checkpoint" in
    Fs_compat.save_file path corrupt;
    (match
       Keeper_checkpoint_store.save_agent_core_classified
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
      |> Agent_core.Checkpoint.to_string
    in
    Fs_compat.save_file path mismatched;
    (match
       Keeper_checkpoint_store.save_agent_core_classified
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
      Keeper_checkpoint_store.save_agent_core_classified
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
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
    | Error _ -> fail "load after concurrent saves failed"
    | Ok checkpoint ->
      check int "canonical disk retains the maximum turn" expected
        checkpoint.Agent_core.Checkpoint.turn_count)

(* The canonical checkpoint file is written compact (Yojson.Safe.to_string),
   not pretty-printed, to cut idle-CPU serialization cost. The read path is a
   JSON parser and is format-agnostic; this test asserts the on-disk bytes are
   actually single-line and that the round-trip through the compact encoding
   is lossless for session identity, turn_count, and message content. *)
let test_canonical_checkpoint_is_written_compact () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-compact" in
    let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:7 ~marker:"compact-marker")
      "compact save";
    let raw = Fs_compat.load_file path in
    check bool "canonical checkpoint bytes are single-line (compact, not pretty)"
      true
      (not (String.contains raw '\n'));
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
    | Error _ -> fail "load after compact save failed"
    | Ok on_disk ->
      check string "session_id round-trips through compact encoding" sid
        on_disk.Agent_core.Checkpoint.session_id;
      check int "turn_count round-trips through compact encoding" 7
        on_disk.Agent_core.Checkpoint.turn_count;
      let marker_present =
        List.exists
          (fun (msg : Agent_core.Types.message) ->
             String.equal (Agent_core.Types.text_of_message msg) "compact-marker")
          on_disk.Agent_core.Checkpoint.messages
      in
      check bool "message content round-trips through compact encoding" true
        marker_present)

let test_ready_runtime_raw_domain_save () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Executor_pool_ref.For_testing.with_pool
    (Domain_pool.executor_pool pool)
  @@ fun () ->
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let session_id = "raw-domain-ready" in
  let session_dir = Filename.concat base_dir "new-session" in
  let result =
    Domain.spawn (fun () ->
      Keeper_checkpoint_store.save_agent_core_classified ~session_dir
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
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
  | Error _ -> fail "raw-domain checkpoint did not round-trip"
  | Ok checkpoint -> check int "raw-domain turn persisted" 11 checkpoint.turn_count

let with_recorded_backtraces f =
  let was_recording = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace was_recording)
    f
;;

let with_exact_source_fixture ~session_id f =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "exact source seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "exact source load failed"
    in
    f ~session_dir ~source_ref)
;;

let test_exact_source_cas_allows_one_equal_turn_writer () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-cas" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "CAS seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS source load failed"
    in
    let left_observed = Atomic.make 0 in
    let right_observed = Atomic.make 0 in
    let left_ref = Atomic.make None in
    let right_ref = Atomic.make None in
    let writer marker observed observed_ref =
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_observer
        ~on_checkpoint_commit_observer:(fun installed_ref ->
          Atomic.incr observed;
          Atomic.set observed_ref (Some installed_ref))
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:8 ~marker)
    in
    let left =
      Domain.spawn (fun () -> "left", writer "left" left_observed left_ref)
    in
    let right =
      Domain.spawn (fun () -> "right", writer "right" right_observed right_ref)
    in
    let committed, changed =
      [ Domain.join left; Domain.join right ]
      |> List.fold_left
           (fun (committed, changed) (marker, outcome) ->
             match outcome with
             | Keeper_checkpoint_store.Installed installed ->
               (marker, installed) :: committed, changed
             | Keeper_checkpoint_store.Not_installed
                 { cause = Keeper_checkpoint_store.Source_changed _; _ } ->
               committed, changed + 1
             | Keeper_checkpoint_store.Not_installed _ ->
               fail "CAS writer returned an unexpected error")
           ([], 0)
    in
    check int "exactly one writer commits" 1 (List.length committed);
    check int "the competing source is rejected" 1 changed;
    check int
      "competing observer is emitted once for the winner"
      1
      (Atomic.get left_observed + Atomic.get right_observed);
    match committed,
      Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
    with
    | [ (winner, committed_ref) ], Ok (checkpoint, disk_ref) ->
      let winner_observed, loser_observed, winner_ref =
        if String.equal winner "left"
        then Atomic.get left_observed, Atomic.get right_observed, Atomic.get left_ref
        else Atomic.get right_observed, Atomic.get left_observed, Atomic.get right_ref
      in
      check int "winning writer observer count" 1 winner_observed;
      check int "stale writer observer count" 0 loser_observed;
      check bool "committed ref identifies installed canonical bytes" true
        (Keeper_checkpoint_ref.equal committed_ref.installed_ref disk_ref);
      check bool
        "observer receives the exact installed ref"
        true
        (match winner_ref with
         | Some observed_ref ->
           Keeper_checkpoint_ref.equal observed_ref committed_ref.installed_ref
         | None -> false);
      check bool "installed payload belongs to the winning writer" true
        (List.exists
           (fun (message : Agent_core.Types.message) ->
             String.equal (Agent_core.Types.text_of_message message) winner)
           checkpoint.messages)
    | _ -> fail "CAS winner did not round-trip")

let test_exact_source_cas_updates_canonical_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-cas-watermark" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "CAS watermark seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS watermark source load failed"
    in
    let release_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Release_process_lock
      ; cause =
          { File_lock_eio.error = Unix.EIO
          ; operation = "injected_release"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    (match
       Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_release_failure
         ~release_failure
         ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
         ~session_dir
         ~expected_source_ref:source_ref
         (make_checkpoint ~session_id ~turn_count:9 ~marker:"target")
     with
     | Keeper_checkpoint_store.Installed installed ->
       check int "release-failure observer remains at-most-once" 1 !observer_count;
       check bool
         "release failure remains auxiliary to installed"
         true
         (List.exists
            (function
              | Keeper_checkpoint_store.Release_process_lock_failed error ->
                error = release_failure
              | _ -> false)
            installed.auxiliary)
       ;
       let disk_ref =
         match
           Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
         with
         | Ok (_, reference) -> reference
         | Error _ -> fail "release-failure installed checkpoint was not readable"
       in
       check bool
         "release failure preserves the exact installed ref"
         true
         (Keeper_checkpoint_ref.equal installed.installed_ref disk_ref)
     | Keeper_checkpoint_store.Not_installed _ ->
       fail "release failure downgraded the installed checkpoint");
    match
      Keeper_checkpoint_store.save_agent_core_classified ~session_dir
        (make_checkpoint ~session_id ~turn_count:8 ~marker:"stale!")
    with
    | Ok
        (Keeper_checkpoint_store.Stale_noop
           { incoming_turn_count; known_turn_count }) ->
      check int "colliding stale input turn" 8 incoming_turn_count;
      check int "CAS candidate remains the admission watermark" 9
        known_turn_count
    | Ok (Keeper_checkpoint_store.Saved _) ->
      fail "stale save ignored the canonical checkpoint installed by CAS"
    | Error error -> fail ("post-CAS stale classification failed: " ^ error))

let test_post_rename_durability_unknown_is_installed () =
  let session_id = "sess-cas-post-rename" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let candidate =
      make_checkpoint ~session_id ~turn_count:9 ~marker:"post-rename"
    in
    let durability_error =
      { Keeper_fs.renamed = true
      ; stage = Keeper_fs.Parent_directory_fsync_after_rename
      ; failure =
          Keeper_fs.Operation_failed "injected post-rename durability failure"
      }
    in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_writer
        ~write_checkpoint_bytes:
          (fun ~on_durable_commit:_ ~ownership_root:_ ~path ~bytes ->
             Fs_compat.save_file path bytes;
             Error durability_error)
        ~on_checkpoint_commit_observer:(fun _ -> ())
        ~session_dir
        ~expected_source_ref:source_ref
        candidate
    with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "post-rename durability uncertainty became Not_installed"
    | Keeper_checkpoint_store.Installed installed ->
      (match installed.auxiliary with
       | [ Keeper_checkpoint_store.Commit_durability_unknown error ] ->
         check bool
           "post-rename durability cause is preserved"
           true
           (error = durability_error)
       | _ -> fail "post-rename durability auxiliary was not preserved");
      let disk_ref =
        match
          Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
        with
        | Ok (_, reference) -> reference
        | Error _ -> fail "post-rename candidate was not externally installed"
      in
      check bool
        "post-rename outcome carries the exact installed ref"
        true
        (Keeper_checkpoint_ref.equal installed.installed_ref disk_ref);
      match
        Keeper_checkpoint_store.save_agent_core_if_source
          ~session_dir
          ~expected_source_ref:source_ref
          candidate
      with
      | Keeper_checkpoint_store.Not_installed
          { cause = Keeper_checkpoint_store.Source_changed actual; _ } ->
        check bool
          "same-process retry is fenced by the installed ref"
          true
          (Keeper_checkpoint_ref.equal actual installed.installed_ref)
      | Keeper_checkpoint_store.Installed _ ->
        fail "post-rename candidate was installed twice"
      | Keeper_checkpoint_store.Not_installed _ ->
        fail "post-rename retry failed without exact source evidence")
;;

let test_pre_rename_write_failure_is_not_installed_and_retryable () =
  let session_id = "sess-cas-pre-rename" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let candidate =
      make_checkpoint ~session_id ~turn_count:9 ~marker:"pre-rename"
    in
    let write_error =
      { Keeper_fs.renamed = false
      ; stage = Keeper_fs.Payload_write
      ; failure = Keeper_fs.Operation_failed "injected pre-rename write failure"
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_writer
        ~write_checkpoint_bytes:
          (fun ~on_durable_commit:_ ~ownership_root:_ ~path:_ ~bytes:_ ->
             Error write_error)
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        candidate
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "pre-rename write failure became Installed"
    | Keeper_checkpoint_store.Not_installed
        { cause = Keeper_checkpoint_store.Commit_not_installed error; _ } ->
      check bool
        "pre-rename write failure preserves its exact cause"
        true
        (error = write_error);
      check int "pre-rename failure emits no commit observer" 0 !observer_count;
      (match
         Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
       with
       | Ok (_, disk_ref) ->
         check bool
           "pre-rename failure leaves the canonical ref unchanged"
           true
           (Keeper_checkpoint_ref.equal source_ref disk_ref)
       | Error _ -> fail "pre-rename failure removed the canonical checkpoint");
      (match
         Keeper_checkpoint_store.save_agent_core_if_source
           ~session_dir
           ~expected_source_ref:source_ref
           candidate
       with
       | Keeper_checkpoint_store.Installed installed ->
         check bool
           "pre-rename failure remains retryable from the same source"
           false
           (Keeper_checkpoint_ref.equal source_ref installed.installed_ref)
       | Keeper_checkpoint_store.Not_installed _ ->
         fail "pre-rename failure consumed the exact-source retry")
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "pre-rename write failure lost its Commit_not_installed cause")
;;

let test_release_failure_preserves_not_installed_cause () =
  let session_id = "sess-cas-not-installed-release" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let advanced =
      match
        Keeper_checkpoint_store.save_agent_core_if_source
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"advanced")
      with
      | Keeper_checkpoint_store.Installed installed -> installed.installed_ref
      | Keeper_checkpoint_store.Not_installed _ ->
        fail "failed to advance the source before release-failure proof"
    in
    let release_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Release_process_lock
      ; cause =
          { File_lock_eio.error = Unix.EIO
          ; operation = "injected_release_after_not_installed"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_release_failure
        ~release_failure
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:10 ~marker:"stale-source")
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "release failure changed a source mismatch into Installed"
    | Keeper_checkpoint_store.Not_installed outcome ->
      (match outcome.cause with
       | Keeper_checkpoint_store.Source_changed actual ->
         check bool
           "Not_installed retains the exact changed source"
           true
           (Keeper_checkpoint_ref.equal actual advanced)
       | _ -> fail "release failure replaced the original non-install cause");
      check int "non-install path emits no commit observer" 0 !observer_count;
      match outcome.auxiliary with
      | [ Keeper_checkpoint_store.Release_process_lock_failed error ] ->
        check bool
          "Not_installed retains the release failure"
          true
          (error = release_failure)
      | _ -> fail "Not_installed release failure was not preserved")
;;

let test_acquire_failure_prevents_lock_body () =
  let session_id = "sess-cas-acquire-failure" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let acquire_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Open_lock_file
      ; cause =
          { File_lock_eio.error = Unix.EACCES
          ; operation = "injected_open_before_body"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_acquire_failure
        ~acquire_failure
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:9 ~marker:"not-admitted")
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "lock acquisition failure admitted the checkpoint body"
    | Keeper_checkpoint_store.Not_installed outcome ->
      check int "acquire failure runs no commit observer" 0 !observer_count;
      check bool "acquire failure has no release auxiliary" true
        (outcome.auxiliary = []);
      match outcome.cause with
      | Keeper_checkpoint_store.Source_unavailable
          (Keeper_checkpoint_store.Ref_lock_failed detail) ->
        check bool
          "acquire failure preserves its exact lock cause"
          true
          (Astring.String.is_infix ~affix:"injected_open_before_body" detail)
      | _ -> fail "acquire failure changed its non-install cause")
;;

let test_commit_observer_failure_is_installed () =
  let session_id = "sess-cas-observer-failure" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let outcome =
      with_recorded_backtraces (fun () ->
        Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_observer
          ~on_checkpoint_commit_observer:(fun _ ->
            failwith "injected commit observer failure")
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"observer-failure"))
    in
    match outcome with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "commit observer failure downgraded the installed checkpoint"
    | Keeper_checkpoint_store.Installed installed ->
      match installed.auxiliary with
      | [ Keeper_checkpoint_store.Commit_observer_failed
            (Failure detail, backtrace) ] ->
        check string
          "commit observer failure cause"
          "injected commit observer failure"
          detail;
        check bool
          "commit observer failure preserves its raw backtrace"
          true
          (Printexc.raw_backtrace_length backtrace > 0)
      | _ -> fail "commit observer failure was not preserved as auxiliary")
;;

let test_post_commit_unwind_is_installed () =
  let session_id = "sess-cas-post-commit-unwind" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let outcome =
      with_recorded_backtraces (fun () ->
        Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_post_commit_unwind
          ~post_commit_unwind:(fun () ->
            failwith "injected post-commit unwind")
          ~on_checkpoint_commit_observer:(fun _ -> ())
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"post-commit-unwind"))
    in
    match outcome with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "post-commit unwind downgraded the installed checkpoint"
    | Keeper_checkpoint_store.Installed installed ->
      match installed.auxiliary with
      | [ Keeper_checkpoint_store.Post_commit_unwind_interrupted
            (Failure detail, backtrace) ] ->
        check string
          "post-commit unwind cause"
          "injected post-commit unwind"
          detail;
        check bool
          "post-commit unwind preserves its raw backtrace"
          true
          (Printexc.raw_backtrace_length backtrace > 0)
      | _ -> fail "post-commit unwind was not preserved as auxiliary")
;;

let test_exact_snapshot_preserves_locked_canonical_bytes () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-snapshot" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:4 ~marker:"exact")
      "exact snapshot seed";
    let canonical_path = Filename.concat session_dir (session_id ^ ".json") in
    let expected_bytes =
      Fs_compat.load_file canonical_path
      |> Yojson.Safe.from_string
      |> Yojson.Safe.pretty_to_string
    in
    Fs_compat.save_file canonical_path expected_bytes;
    match
      Keeper_checkpoint_store.load_agent_core_exact_snapshot
        ~session_dir
        ~session_id
    with
    | Error _ -> fail "exact snapshot load failed"
    | Ok snapshot ->
      check string "canonical bytes are not re-encoded" expected_bytes
        (Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot);
      let reference =
        Keeper_checkpoint_store.exact_snapshot_reference snapshot
      in
      let expected_session_id =
        Result.get_ok (Keeper_id.Trace_id.of_string session_id)
      in
      match
        Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes
          ~expected_session_id
          expected_bytes
      with
      | Ok decoded ->
        check bool "pure decode derives the same exact ref" true
          (Keeper_checkpoint_ref.equal reference
             (Keeper_checkpoint_store.exact_snapshot_reference decoded))
      | Error _ -> fail "exact snapshot bytes did not decode")

(* RFC main-domain-scheduler-latency §8 P4b. After a save, the store answers
   the save watermark and the message count from its canonical summary while
   the file on disk is the one it wrote. The file is made unreadable to show
   that neither answer reads it. *)
let test_byte_count_from_summary_without_reading () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "byte-count-no-read" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"three")
    "save turn 3";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let on_disk = (Unix.stat path).Unix.st_size in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  (match Keeper_checkpoint_store.canonical_byte_count ~session_dir ~session_id:sid with
   | Ok (Some bytes) -> check int "byte count is the file's size" on_disk bytes
   | Ok None -> fail "byte count reported no checkpoint"
   | Error _ -> fail "byte count read the unreadable file");
  match Keeper_checkpoint_store.canonical_byte_count ~session_dir ~session_id:"absent" with
  | Ok None -> ()
  | Ok (Some _) -> fail "an absent session reported bytes"
  | Error _ -> fail "an absent session is not a store error"
;;

let test_summary_answers_watermark_and_count_without_reading () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "summary-no-read" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"three")
    "save turn 3";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  (match
     Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
   with
   | Ok (Some count) -> check int "message count from the summary" 2 count
   | Ok None -> fail "summary reported no checkpoint"
   | Error _ -> fail "message count read the unreadable file");
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~session_dir
      (make_checkpoint ~session_id:sid ~turn_count:2 ~marker:"stale")
  with
  | Ok
      (Keeper_checkpoint_store.Stale_noop
         { incoming_turn_count = 2; known_turn_count = 3 }) -> ()
  | Ok (Keeper_checkpoint_store.Stale_noop _) ->
    fail "stale verdict carried other turn counts"
  | Ok (Keeper_checkpoint_store.Saved _) -> fail "a stale turn was saved"
  | Error e -> fail ("watermark read the unreadable file: " ^ e)
;;

(* A canonical file replaced behind the store (another process, an operator)
   is a new inode, so the summary no longer matches and the next answer
   parses the file; a removed file answers as no checkpoint. *)
(* The canonical read goes through the owned-file reader: a canonical path
   that is a symbolic link out of the session's ownership chain is refused
   as an I/O error instead of being followed. *)
let test_checkpoint_read_refuses_a_symlinked_canonical_file () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "symlinked-canonical" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"one")
    "save turn 1";
  (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
   | Ok checkpoint -> check int "regular canonical file loads" 1 checkpoint.turn_count
   | Error error ->
     failf "regular canonical file failed: %s"
       (Keeper_checkpoint_store.checkpoint_load_error_to_string error));
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let outside = Filename.temp_file "ckpt_outside_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove outside with Sys_error _ -> ()) @@ fun () ->
  Out_channel.with_open_bin outside (fun channel ->
    output_string channel (In_channel.with_open_bin path In_channel.input_all));
  Sys.remove path;
  Unix.symlink outside path;
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
  | Error (Keeper_checkpoint_store.Io_error _) -> ()
  | Error error ->
    failf "symlinked canonical file refused with the wrong class: %s"
      (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  | Ok _ -> fail "symlinked canonical file was followed"

let test_summary_follows_a_checkpoint_replaced_behind_it () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "summary-replaced" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"one")
    "save turn 1";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let replacement =
    let base = make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"five" in
    { base with
      messages =
        base.messages
        @ [ Agent_core.Types.
              { role = User
              ; content = [ Text "again" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
          ]
    }
  in
  let staged = path ^ ".replacement" in
  Out_channel.with_open_bin staged (fun channel ->
    output_string
      channel
      (Yojson.Safe.to_string (Agent_core.Checkpoint.to_json replacement)));
  Sys.rename staged path;
  (match
     Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
   with
   | Ok (Some count) -> check int "message count of the replacement" 3 count
   | Ok None -> fail "replacement reported no checkpoint"
   | Error _ -> fail "replacement could not be read");
  (match
     Keeper_checkpoint_store.save_agent_core_classified
       ~session_dir
       (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"four")
   with
   | Ok
       (Keeper_checkpoint_store.Stale_noop
          { incoming_turn_count = 4; known_turn_count = 5 }) -> ()
   | Ok (Keeper_checkpoint_store.Stale_noop _) ->
     fail "stale verdict carried other turn counts"
   | Ok (Keeper_checkpoint_store.Saved _) ->
     fail "the watermark still answered from the old summary"
   | Error e -> fail ("save failed: " ^ e));
  Sys.remove path;
  match
    Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
  with
  | Ok None -> ()
  | Ok (Some _) -> fail "a removed checkpoint still answered from the summary"
  | Error _ -> fail "a removed checkpoint was reported as an error"
;;

let () =
  run "Keeper_checkpoint_store checkpoint watermark (RFC-0225 §3.2)"
    [
      ( "checkpoint transaction",
        [
          test_case "run context binds generation before AGENT_CORE checkpoint" `Quick
            test_run_context_binds_generation_before_agent_core_checkpoint;
          test_case "forward and equal saves pass, stale save is no-op" `Quick
            test_forward_equal_and_stale;
          test_case "canonical disk is the watermark SSOT" `Quick
            test_disk_is_the_watermark_ssot;
          test_case "external canonical replacement is the watermark" `Quick
            test_externally_replaced_canonical_is_the_watermark;
          test_case "empty session_id is refused, not silently dropped" `Quick
            test_empty_session_id_rejected;
          test_case "session leaf escapes and symlink leaves are refused" `Quick
            test_session_leaf_containment;
          test_case "history snapshot ids cannot reach outside the session" `Quick
            test_history_snapshot_id_containment;
          test_case "invalid canonical checkpoint fails closed" `Quick
            test_invalid_existing_checkpoint_fails_closed;
          test_case "multi-domain writers leave max turn on disk" `Quick
            test_multi_domain_writers_leave_max_turn_on_disk;
          test_case "ready runtime raw Domain saves through Unix context" `Quick
            test_ready_runtime_raw_domain_save;
          test_case "canonical checkpoint is written compact and round-trips" `Quick
            test_canonical_checkpoint_is_written_compact;
          test_case "exact source CAS permits one equal-turn writer" `Quick
            test_exact_source_cas_allows_one_equal_turn_writer;
          test_case "exact source CAS updates the canonical watermark" `Quick
            test_exact_source_cas_updates_canonical_watermark;
          test_case "release failure preserves Not_installed cause" `Quick
            test_release_failure_preserves_not_installed_cause;
          test_case "acquire failure prevents the lock body" `Quick
            test_acquire_failure_prevents_lock_body;
          test_case "post-rename durability uncertainty stays installed" `Quick
            test_post_rename_durability_unknown_is_installed;
          test_case "pre-rename write failure stays retryable" `Quick
            test_pre_rename_write_failure_is_not_installed_and_retryable;
          test_case "commit observer failure stays installed" `Quick
            test_commit_observer_failure_is_installed;
          test_case "post-commit unwind stays installed" `Quick
            test_post_commit_unwind_is_installed;
          test_case "exact snapshot preserves canonical bytes" `Quick
            test_exact_snapshot_preserves_locked_canonical_bytes;
          test_case "structurally invalid checkpoint is refused at the store" `Quick
            test_structurally_invalid_checkpoint_is_refused_at_the_store;
          test_case "a valid checkpoint still saves" `Quick
            test_valid_checkpoint_still_saves;
          test_case "an unencodable payload is recovered at the sink" `Quick
            test_unencodable_payload_is_recovered_at_the_sink;
          test_case "summary answers watermark and count without reading" `Quick
            test_summary_answers_watermark_and_count_without_reading;
          test_case "byte count comes from the summary without reading" `Quick
            test_byte_count_from_summary_without_reading;
          test_case "summary follows a checkpoint replaced behind it" `Quick
            test_summary_follows_a_checkpoint_replaced_behind_it;
          test_case "canonical read refuses a symlinked file" `Quick
            test_checkpoint_read_refuses_a_symlinked_canonical_file;
        ] );
    ]
