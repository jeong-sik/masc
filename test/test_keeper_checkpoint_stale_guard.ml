(** RFC-0225 §3.2: stale OAS checkpoint writes are a disk-SSOT no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_oas_classified] skips a save whose [turn_count] is older
    than the canonical checkpoint observed inside the save transaction, without
    turning that watermark hit into keeper lifecycle failure.

    Also covers the checkpoint save-path read-modify-write perf fix: a
    fingerprinted sidecar file (size + mtime of the canonical file) lets a
    save skip re-parsing the canonical JSON when nothing has touched it
    since the sidecar was written, while every decision is still re-verified
    against a fresh disk `stat` (no process-local watermark state -- see
    #24561 / commit 20536cacbf, which removed exactly that structure for
    this reason). The canonical file itself is now written compact rather
    than pretty-printed. *)

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

(* The canonical checkpoint file is still the only durable admission
   watermark (RFC-0225 §3.2). This save's stale-check happens to be served
   by the fingerprint-matched sidecar fast path (nothing touched the
   canonical file between the seed save and the stale check, so the sidecar
   [size]/[mtime] fingerprint still matches) -- [test_fingerprint_match_skips_full_parse]
   below proves that explicitly via the parse-count hook; this test only
   asserts the observable outcome is unchanged from the pre-sidecar
   disk-only behavior. *)
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

(* RFC-0225 §3.2 fast path: once a session's sidecar fingerprint matches the
   canonical file's current (size, mtime), [load_canonical_strict] must not
   run again. A correct answer alone would not distinguish "read the
   sidecar" from "re-parsed canonical and happened to get the same result",
   so this asserts the parse-count hook directly. *)
let test_fingerprint_match_skips_full_parse () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-fastpath" in
    Keeper_checkpoint_store.For_testing.reset_full_parse_count ();
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"v5")
      "seed save (cold: no canonical file yet, so this necessarily falls back once)";
    check int "cold seed save runs exactly one full-parse fallback" 1
      (Keeper_checkpoint_store.For_testing.get_full_parse_count ());
    Keeper_checkpoint_store.For_testing.reset_full_parse_count ();
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:6 ~marker:"v6")
      "forward save served by the sidecar fast path";
    check int "fingerprint-matched forward save skips the full parse" 0
      (Keeper_checkpoint_store.For_testing.get_full_parse_count ());
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"v4-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
             { incoming_turn_count; known_turn_count }) ->
       check int "fast-path stale incoming turn_count" 4 incoming_turn_count;
       check int "fast-path known turn_count" 6 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) -> fail "stale save advanced via the fast path"
     | Error e -> fail ("fast-path stale save returned lifecycle failure: " ^ e));
    check int "fingerprint-matched stale check also skips the full parse" 0
      (Keeper_checkpoint_store.For_testing.get_full_parse_count ()))

(* Sidecar absent or corrupt: the fast path must never blindly trust a
   missing/unparseable sidecar. Both sub-cases fall back to the ORIGINAL
   full-parse path unconditionally (the exact path this module used before
   this fix) and heal the sidecar afterward so the next save can use the
   fast path again. *)
let test_sidecar_unusable_falls_back_to_full_parse () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-sidecar-unusable" in
    let sidecar_path =
      Keeper_checkpoint_store.watermark_sidecar_path
        (Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id:sid)
    in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:8 ~marker:"v8")
      "seed save (writes canonical + sidecar)";
    check bool "seed save writes a sidecar" true (Fs_compat.file_exists sidecar_path);
    (* Sub-case 1: sidecar deleted outright. *)
    Sys.remove sidecar_path;
    Keeper_checkpoint_store.For_testing.reset_full_parse_count ();
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"v3-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
             { incoming_turn_count; known_turn_count }) ->
       check int "sidecar-absent stale incoming turn_count" 3 incoming_turn_count;
       check int "sidecar-absent known turn_count recovered from canonical" 8 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) -> fail "stale save advanced with an absent sidecar"
     | Error e -> fail ("sidecar-absent stale save returned lifecycle failure: " ^ e));
    check bool "sidecar-absent path ran the full-parse fallback" true
      (Keeper_checkpoint_store.For_testing.get_full_parse_count () > 0);
    check bool "the fallback healed the sidecar" true (Fs_compat.file_exists sidecar_path);
    (* Sub-case 2: sidecar present but corrupt (unparseable JSON). *)
    Fs_compat.save_file sidecar_path "{not-json";
    Keeper_checkpoint_store.For_testing.reset_full_parse_count ();
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:2 ~marker:"v2-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
             { incoming_turn_count; known_turn_count }) ->
       check int "corrupt-sidecar stale incoming turn_count" 2 incoming_turn_count;
       check int "corrupt-sidecar known turn_count recovered from canonical" 8 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) -> fail "stale save advanced with a corrupt sidecar"
     | Error e -> fail ("corrupt-sidecar stale save returned lifecycle failure: " ^ e));
    check bool "corrupt-sidecar path ran the full-parse fallback" true
      (Keeper_checkpoint_store.For_testing.get_full_parse_count () > 0))

(* Fingerprint mismatch: a canonical write that bypasses [save_oas_classified]
   (a different writer, or a crash between a writer's own canonical write and
   its sidecar update) leaves the sidecar stale relative to disk. The next
   save must detect the (size, mtime) mismatch and recover the REAL watermark
   from a full parse of canonical, not the stale sidecar's belief -- this is
   exactly the drift the removed in-memory cache (#24561 / commit 20536cacbf)
   could not detect, because it had no way to notice a canonical write it did
   not itself perform. *)
let test_fingerprint_mismatch_recovers_externally_written_canonical () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-external-write" in
    let canonical_path =
      Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id:sid
    in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"v5")
      "seed save (sidecar now records turn_count=5)";
    (* Simulate a different writer updating canonical directly without
       updating the sidecar. A much longer marker guarantees the byte size
       differs, so the fingerprint mismatch is detected regardless of
       filesystem mtime resolution. *)
    Fs_compat.save_file canonical_path
      (make_checkpoint ~session_id:sid ~turn_count:9
         ~marker:"externally-written-turn-nine-with-a-much-longer-marker-to-force-a-size-change"
       |> Agent_sdk.Checkpoint.to_string);
    Keeper_checkpoint_store.For_testing.reset_full_parse_count ();
    (match
       Keeper_checkpoint_store.save_oas_classified ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:7
            ~marker:"v7-would-wrongly-look-forward-against-a-stale-sidecar")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
             { incoming_turn_count; known_turn_count }) ->
       check int "incoming turn_count" 7 incoming_turn_count;
       check int "known turn_count is the real canonical value, not the stale sidecar's" 9
         known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "turn_count=7 was wrongly accepted as forward against a stale sidecar's turn_count=5"
     | Error e -> fail ("fingerprint-mismatch save returned lifecycle failure: " ^ e));
    check bool "fingerprint mismatch ran the full-parse fallback" true
      (Keeper_checkpoint_store.For_testing.get_full_parse_count () > 0);
    match Keeper_checkpoint_store.load_oas ~session_dir ~session_id:sid with
    | Ok on_disk ->
      check int "externally-written turn_count=9 remains on disk, untouched by the stale save" 9
        on_disk.Agent_sdk.Checkpoint.turn_count
    | Error _ -> fail "load after fingerprint-mismatch stale rejection failed")

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
          test_case "fingerprint-matched sidecar skips the full parse" `Quick
            test_fingerprint_match_skips_full_parse;
          test_case "absent or corrupt sidecar falls back to full parse" `Quick
            test_sidecar_unusable_falls_back_to_full_parse;
          test_case "fingerprint mismatch recovers an externally-written canonical" `Quick
            test_fingerprint_mismatch_recovers_externally_written_canonical;
          test_case "canonical checkpoint is written compact and round-trips" `Quick
            test_canonical_checkpoint_is_written_compact;
        ] );
    ]
