(** RFC-0225 §3.2: stale OAS checkpoint writes are a disk-SSOT no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_oas_classified] skips a save whose [turn_count] is older
    than the canonical checkpoint observed inside the save transaction, without
    turning that watermark hit into keeper lifecycle failure.

    The canonical file is parsed under the stable session lock for every
    admission decision. No process-local cache, fingerprint, or sidecar may
    substitute for the checkpoint bytes. The canonical file is written in
    compact JSON. *)

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

let with_generation generation (checkpoint : Agent_sdk.Checkpoint.t) =
  let context = Agent_sdk.Context.copy ~eio:false checkpoint.context in
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    Keeper_checkpoint_store.keeper_generation_context_key (`Int generation);
  { checkpoint with context }

let save_ok ~session_dir ckpt label =
  match Keeper_checkpoint_store.save_oas_classified ~session_dir ckpt with
  | Ok _ -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)

let test_run_context_binds_generation_before_oas_checkpoint () =
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
  let shared_context = Agent_sdk.Context.create () in
  let run_context =
    Keeper_run_context.prepare_run_context
      ~config:(Workspace.default_config base_dir)
      ~meta
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~base_dir
      ~runtime_id:"unconfigured-test-runtime"
      ~shared_context
      ~generation:7
      ()
  in
  check bool "caller-owned context remains the OAS context" true
    (run_context.shared_context == shared_context);
  let agent =
    Agent_sdk.Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:(Agent_sdk.Agent.default_config ~model:"test-model")
      ~context:run_context.shared_context
      ()
  in
  let checkpoint = Agent_sdk.Agent.checkpoint agent in
  match
    Agent_sdk.Context.get_scoped checkpoint.context Agent_sdk.Context.Session
      Keeper_checkpoint_store.keeper_generation_context_key
  with
  | Some (`Int generation) ->
    check int "OAS checkpoint carries current keeper generation" 7 generation
  | _ -> fail "OAS checkpoint omitted the bound keeper generation"

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

let test_externally_replaced_canonical_is_the_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-external-write" in
    let canonical_path =
      Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id
    in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:5 ~marker:"v5")
      "seed save";
    Fs_compat.save_file canonical_path
      (make_checkpoint ~session_id ~turn_count:9 ~marker:"external-v9"
       |> Agent_sdk.Checkpoint.to_string);
    match
      Keeper_checkpoint_store.save_oas_classified ~session_dir
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
         Keeper_checkpoint_store.delete_oas_history_files ~session_dir
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
        Keeper_checkpoint_store.load_oas_history_file ~session_dir
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

(* The canonical checkpoint file is written compact (Yojson.Safe.to_string),
   not pretty-printed, to cut idle-CPU serialization cost. The read path is a
   JSON parser and is format-agnostic; this test asserts the on-disk bytes are
   actually single-line and that the round-trip through the compact encoding
   is lossless for session identity, turn_count, and message content. *)
let test_canonical_checkpoint_is_written_compact () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-compact" in
    let path = Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id:sid in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:7 ~marker:"compact-marker")
      "compact save";
    let raw = Fs_compat.load_file path in
    check bool "canonical checkpoint bytes are single-line (compact, not pretty)"
      true
      (not (String.contains raw '\n'));
    match Keeper_checkpoint_store.load_oas ~session_dir ~session_id:sid with
    | Error _ -> fail "load after compact save failed"
    | Ok on_disk ->
      check string "session_id round-trips through compact encoding" sid
        on_disk.Agent_sdk.Checkpoint.session_id;
      check int "turn_count round-trips through compact encoding" 7
        on_disk.Agent_sdk.Checkpoint.turn_count;
      let marker_present =
        List.exists
          (fun (msg : Agent_sdk.Types.message) ->
             String.equal (Agent_sdk.Types.text_of_message msg) "compact-marker")
          on_disk.Agent_sdk.Checkpoint.messages
      in
      check bool "message content round-trips through compact encoding" true
        marker_present)

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

let test_exact_source_cas_allows_one_equal_turn_writer () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-cas" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source"
       |> with_generation 3)
      "CAS seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_oas_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS source load failed"
    in
    let writer marker =
      Keeper_checkpoint_store.save_oas_if_source
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:8 ~marker
         |> with_generation 3)
    in
    let left = Domain.spawn (fun () -> "left", writer "left") in
    let right = Domain.spawn (fun () -> "right", writer "right") in
    let committed, changed =
      [ Domain.join left; Domain.join right ]
      |> List.fold_left
           (fun (committed, changed) (marker, outcome) ->
             match outcome with
             | Ok reference -> (marker, reference) :: committed, changed
             | Error (Keeper_checkpoint_store.Source_changed _) ->
               committed, changed + 1
             | Error _ -> fail "CAS writer returned an unexpected error")
           ([], 0)
    in
    check int "exactly one writer commits" 1 (List.length committed);
    check int "the competing source is rejected" 1 changed;
    match committed,
      Keeper_checkpoint_store.load_oas_with_ref ~session_dir ~session_id
    with
    | [ (winner, committed_ref) ], Ok (checkpoint, disk_ref) ->
      check bool "committed ref identifies installed canonical bytes" true
        (Keeper_checkpoint_ref.equal committed_ref disk_ref);
      check bool "installed payload belongs to the winning writer" true
        (List.exists
           (fun (message : Agent_sdk.Types.message) ->
             String.equal (Agent_sdk.Types.text_of_message message) winner)
           checkpoint.messages)
    | _ -> fail "CAS winner did not round-trip")

let test_exact_source_cas_updates_canonical_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-cas-watermark" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source"
       |> with_generation 3)
      "CAS watermark seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_oas_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS watermark source load failed"
    in
    (match
       Keeper_checkpoint_store.save_oas_if_source
         ~session_dir
         ~expected_source_ref:source_ref
         (make_checkpoint ~session_id ~turn_count:9 ~marker:"target"
          |> with_generation 3)
     with
     | Ok _ -> ()
     | Error _ -> fail "CAS watermark candidate did not commit");
    match
      Keeper_checkpoint_store.save_oas_classified ~session_dir
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

let test_checkpoint_ref_requires_generation () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-ref-generation" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:1 ~marker:"missing-generation")
      "generation-less seed";
    match Keeper_checkpoint_store.load_oas_with_ref ~session_dir ~session_id with
    | Error
        (Keeper_checkpoint_store.Ref_identity_invalid
           Keeper_checkpoint_store.Generation_missing) -> ()
    | _ -> fail "generation-less checkpoint acquired an exact ref")

let test_exact_snapshot_preserves_locked_canonical_bytes () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-snapshot" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:4 ~marker:"exact"
       |> with_generation 2)
      "exact snapshot seed";
    let canonical_path = Filename.concat session_dir (session_id ^ ".json") in
    let expected_bytes =
      Fs_compat.load_file canonical_path
      |> Yojson.Safe.from_string
      |> Yojson.Safe.pretty_to_string
    in
    Fs_compat.save_file canonical_path expected_bytes;
    match
      Keeper_checkpoint_store.load_oas_exact_snapshot
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

let () =
  run "Keeper_checkpoint_store checkpoint watermark (RFC-0225 §3.2)"
    [
      ( "checkpoint transaction",
        [
          test_case "run context binds generation before OAS checkpoint" `Quick
            test_run_context_binds_generation_before_oas_checkpoint;
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
          test_case "checkpoint refs require keeper generation" `Quick
            test_checkpoint_ref_requires_generation;
          test_case "exact snapshot preserves canonical bytes" `Quick
            test_exact_snapshot_preserves_locked_canonical_bytes;
        ] );
    ]
