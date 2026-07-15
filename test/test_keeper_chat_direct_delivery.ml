open Alcotest

module Direct = Masc.Keeper_chat_direct_delivery
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_fs = Masc.Keeper_fs
module Keeper_msg_async = Masc.Keeper_msg_async
module Keeper_types_profile = Masc.Keeper_types_profile

let () = Mirage_crypto_rng_unix.use_default ()

let eio_test_case name speed test =
  test_case name speed (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio_guard.enable ();
      Fun.protect
        ~finally:(fun () ->
          Keeper_msg_async.For_testing.clear ();
          Eio_guard.disable ();
          Fs_compat.clear_fs ())
        (fun () -> test env)))
;;

let expect_ok = function
  | Ok value -> value
  | Error error -> fail (Direct.error_to_string error)
;;

let request_id wire =
  Direct.Request_id.of_string wire
  |> function
  | Ok request_id -> request_id
  | Error detail -> fail detail
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_dir f =
  let path = Filename.temp_file "keeper-chat-direct-delivery" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree path)
    (fun () -> Eio.Switch.run (fun background_sw -> f path background_sw))
;;

let direct_request keeper_name =
  let direct : Keeper_direct_invocation.t =
    { execution_prompt = "소스코드를 확인해"
    ; attachments = []
    ; user_blocks = [ Keeper_direct_invocation.User_text "소스코드를 확인해" ]
    ; turn_instructions = None
    ; connector_context = None
    ; continuation_channel =
        Keeper_continuation_channel.Dashboard { thread_id = "dashboard-session" }
    ; projection =
        { user_content = "소스코드를 확인해"
        ; surface = Surface_ref.Dashboard { session_id = Some "dashboard-session" }
        ; conversation_id = Some "conversation-1"
        ; external_message_id = None
        ; speaker =
            { speaker_id = Some "owner"
            ; speaker_name = Some "Owner"
            ; speaker_authority = Keeper_direct_invocation.Owner
            }
        }
    }
  in
  match Keeper_invocation_types.direct_turn ~keeper_name direct with
  | Ok request -> request
  | Error reason -> fail reason
;;

let payload ?(keeper_name = "sangsu") ?(submitted_by = "owner") () :
    Direct.accepted_payload =
  { keeper_name
  ; submitted_by
  ; user_content = "소스코드를 확인해"
  ; user_attachments = []
  ; surface = Surface_ref.Dashboard { session_id = Some "dashboard-session" }
  ; conversation_id = Some "conversation-1"
  ; external_message_id = None
  ; speaker =
      { speaker_id = Some "owner"
      ; speaker_name = Some "Owner"
      ; speaker_authority = Keeper_chat_store.Owner
      }
  }
;;

let assistant_effect ?(body = "completed") () : Direct.staged_effect =
  { request_result =
      { ok = true
      ; body
      ; data = Some (`Assoc [ "result", `String "reviewed" ])
      }
  ; transcript_effect =
      Direct.Assistant_reply
        { content = "소스코드를 확인했다"
        ; blocks = None
        ; turn_ref = None
        }
  }
;;

let accepted_request_id = function
  | Ok
      ({ request_id; acceptance = Keeper_msg_async.Durably_accepted }
        : Keeper_msg_async.submit_outcome) -> request_id
  | Ok outcome ->
    fail
      (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
  | Error error ->
    fail (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
;;

let submit_canonical_request ~background_sw ~base_path request_id =
  let request_id_wire = Direct.Request_id.to_string request_id in
  let ops =
    Keeper_msg_async.For_testing.make_request_ops
      ~generate_request_id:(fun () -> request_id_wire)
      ()
  in
  let submitted =
    Keeper_msg_async.For_testing.submit
      ops
      ~background_sw
      ~base_path
      ~caller:"owner"
      ~request:(direct_request "sangsu")
      ~f:(fun _ -> Keeper_types_profile.tool_result_ok "completed")
      ()
    |> accepted_request_id
  in
  check string "canonical request id" request_id_wire submitted
;;

let prepare ?(submit_request = true) ~background_sw ~base_path ~request_id ~payload ~now =
  if submit_request then submit_canonical_request ~background_sw ~base_path request_id;
  Direct.prepare ~base_path ~request_id ~payload ~now
;;

let prepare_for_testing io ~background_sw ~base_path ~request_id ~payload ~now =
  submit_canonical_request ~background_sw ~base_path request_id;
  Direct.For_testing.prepare io ~base_path ~request_id ~payload ~now
;;

type flow =
  { prepared : Direct.t
  ; user_committed : Direct.t
  ; running : Direct.t
  ; effect_staged : Direct.t
  ; transcript_committed : Direct.t
  }

let complete_flow
      ?(time_offset = 0.0)
      ?(submit_request = true)
      ~background_sw
      ~base_path
      ~request_id
      ()
  =
  let at value = time_offset +. value in
  let prepared =
    prepare
      ~submit_request
      ~background_sw
      ~base_path
      ~request_id
      ~payload:(payload ())
      ~now:(at 1.0)
    |> expect_ok
  in
  let user_committed =
    Direct.commit_user_row ~base_path ~identity:prepared ~now:(at 2.0)
    |> expect_ok
  in
  let running =
    Direct.mark_running ~base_path ~identity:user_committed ~now:(at 3.0)
    |> expect_ok
  in
  let effect_staged =
    Direct.stage_effect
      ~base_path
      ~identity:running
      ~staged:(assistant_effect ())
      ~now:(at 4.0)
    |> expect_ok
  in
  let transcript_committed =
    Direct.commit_transcript
      ~base_path
      ~identity:effect_staged
      ~now:(at 5.0)
    |> expect_ok
  in
  { prepared; user_committed; running; effect_staged; transcript_committed }
;;

let test_direct_flow_is_active_only _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-flow" in
    let flow = complete_flow ~background_sw ~base_path ~request_id () in
    check int64 "five active phases produce four revisions" 4L flow.transcript_committed.revision;
    let loaded =
      Direct.load ~base_path ~keeper_name:"sangsu" ~request_id |> expect_ok
    in
    (match loaded.phase with
     | Direct.Transcript_committed { transcript_row_id; _ } ->
       check bool "transcript row id is present" true
         (not (String.equal transcript_row_id ""))
     | phase ->
       failf
         "expected transcript_committed, got %s"
         (Direct.phase_kind_to_string (Direct.phase_kind phase)));
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "one user and one assistant row" 2 (List.length history))
;;

let test_canonical_request_drives_user_projection _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-canonical-projection" in
    submit_canonical_request ~background_sw ~base_path request_id;
    let checkpoint_payload =
      { (payload ()) with user_content = "stale checkpoint projection" }
    in
    let prepared =
      Direct.prepare ~base_path ~request_id ~payload:checkpoint_payload ~now:1.0
      |> expect_ok
    in
    ignore
      (Direct.commit_user_row ~base_path ~identity:prepared ~now:2.0
       |> expect_ok
        : Direct.t);
    match Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" with
    | [ message ] ->
      check string
        "canonical typed request owns the user projection"
        "소스코드를 확인해"
        message.content
    | history -> failf "expected one canonical user row, got %d" (List.length history))
;;

let fail_after_rename_io () =
  Direct.For_testing.make_io
    ~before_durable_write:(function
      | Keeper_fs.Parent_directory_fsync_after_rename ->
        failwith "synthetic post-rename fsync failure"
      | Keeper_fs.Directory_prepare
      | Keeper_fs.Payload_encode
      | Keeper_fs.Temp_file_create
      | Keeper_fs.Payload_write
      | Keeper_fs.Payload_fsync
      | Keeper_fs.Temp_file_close
      | Keeper_fs.Atomic_rename
      | Keeper_fs.Temp_directory_fsync_after_rename -> ())
    ()
;;

let expect_published_indeterminate = function
  | Error
      (Direct.Persistence_failed
         { publication = Direct.Published_indeterminate; _ }) -> ()
  | Error error -> fail (Direct.error_to_string error)
  | Ok _ -> fail "post-rename failure was silently reported as success"
;;

let test_post_rename_ambiguity_is_reconcilable _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-published-indeterminate" in
    let io = fail_after_rename_io () in
    prepare_for_testing
      io
      ~background_sw
      ~base_path
      ~request_id
      ~payload:(payload ())
      ~now:1.0
    |> expect_published_indeterminate;
    let prepared =
      Direct.load ~base_path ~keeper_name:"sangsu" ~request_id |> expect_ok
    in
    check int64 "published prepare is exactly revision zero" 0L prepared.revision;
    Direct.For_testing.commit_user_row
      io
      ~base_path
      ~identity:prepared
      ~now:2.0
    |> expect_published_indeterminate;
    let committed =
      Direct.load ~base_path ~keeper_name:"sangsu" ~request_id |> expect_ok
    in
    check int64 "published transition is observable by exact load" 1L committed.revision;
    (match Direct.commit_user_row ~base_path ~identity:prepared ~now:3.0 with
     | Error (Direct.Revision_conflict { expected = 0L; actual = 1L }) -> ()
     | Error error -> fail (Direct.error_to_string error)
     | Ok _ -> fail "stale retry advanced the checkpoint twice");
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "append-once kept one accepted user row" 1 (List.length history))
;;

let test_transcript_append_crash_retries_once _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-transcript-crash" in
    let prepared =
      prepare
        ~background_sw
        ~base_path
        ~request_id
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let user_committed =
      Direct.commit_user_row ~base_path ~identity:prepared ~now:2.0 |> expect_ok
    in
    let running =
      Direct.mark_running ~base_path ~identity:user_committed ~now:3.0
      |> expect_ok
    in
    let staged =
      Direct.stage_effect
        ~base_path
        ~identity:running
        ~staged:(assistant_effect ())
        ~now:4.0
      |> expect_ok
    in
    let fail_before_publication =
      Direct.For_testing.make_io
        ~before_durable_write:(function
          | Keeper_fs.Payload_write -> failwith "synthetic checkpoint write crash"
          | Keeper_fs.Directory_prepare
          | Keeper_fs.Payload_encode
          | Keeper_fs.Temp_file_create
          | Keeper_fs.Payload_fsync
          | Keeper_fs.Temp_file_close
          | Keeper_fs.Atomic_rename
          | Keeper_fs.Parent_directory_fsync_after_rename
          | Keeper_fs.Temp_directory_fsync_after_rename -> ())
        ()
    in
    (match
       Direct.For_testing.commit_transcript
         fail_before_publication
         ~base_path
         ~identity:staged
         ~now:5.0
     with
     | Error
         (Direct.Persistence_failed { publication = Direct.Not_published; _ }) -> ()
     | Error error -> fail (Direct.error_to_string error)
     | Ok _ -> fail "pre-publication crash was reported as success");
    ignore
      (Direct.commit_transcript ~base_path ~identity:staged ~now:6.0
       |> expect_ok
        : Direct.t);
    let history = Keeper_chat_store.load ~base_dir:base_path ~keeper_name:"sangsu" in
    check int "retry preserved exactly one user and one assistant" 2
      (List.length history))
;;

let test_mutations_do_not_inventory_the_lane _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-exact-hot-path" in
    let prepared =
      prepare
        ~background_sw
        ~base_path
        ~request_id
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let active_dir =
      Direct.For_testing.active_dir ~base_path ~keeper_name:"sangsu"
      |> expect_ok
    in
    Unix.mkdir (Filename.concat active_dir "foreign-entry") 0o700;
    let user_committed =
      Direct.commit_user_row ~base_path ~identity:prepared ~now:2.0 |> expect_ok
    in
    let running =
      Direct.mark_running ~base_path ~identity:user_committed ~now:3.0
      |> expect_ok
    in
    let staged =
      Direct.stage_effect
        ~base_path
        ~identity:running
        ~staged:(assistant_effect ())
        ~now:4.0
      |> expect_ok
    in
    ignore
      (Direct.commit_transcript ~base_path ~identity:staged ~now:5.0
       |> expect_ok
        : Direct.t);
    match Direct.inspect_lane ~base_path ~keeper_name:"sangsu" |> expect_ok with
    | Direct.Quarantined { recoverable; artifacts = [ artifact ] } ->
      check int "exact record remains recoverable" 1 (List.length recoverable);
      (match artifact.reason with
       | Direct.Active_entry_not_regular -> ()
       | _ -> fail "foreign directory received the wrong quarantine reason")
    | Direct.Quarantined { artifacts; _ } ->
      failf "expected one quarantine artifact, got %d" (List.length artifacts)
    | Direct.Ready _ -> fail "foreign active entry was silently ignored")
;;

let test_lane_quarantine_is_local_and_legacy_is_ignored _env =
  with_temp_dir (fun base_path _background_sw ->
    let legacy_dir =
      Direct.For_testing.active_dir ~base_path ~keeper_name:"sangsu"
      |> expect_ok
      |> Filename.dirname
      |> fun keeper_root -> Filename.concat keeper_root ".chat-deliveries"
    in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir "retired.json") "not-json";
    (match Direct.inspect_lane ~base_path ~keeper_name:"sangsu" |> expect_ok with
     | Direct.Ready [] -> ()
     | Direct.Ready _ -> fail "retired journal created a direct record"
     | Direct.Quarantined _ -> fail "retired journal contaminated the new lane");
    let staging_dir =
      Direct.For_testing.staging_dir ~base_path ~keeper_name:"sangsu"
      |> expect_ok
    in
    Fs_compat.mkdir_p staging_dir;
    Fs_compat.save_file (Filename.concat staging_dir "foreign") "artifact";
    (match Direct.inspect_lane ~base_path ~keeper_name:"sangsu" |> expect_ok with
     | Direct.Quarantined
         { artifacts = [ { reason = Direct.Unexpected_staging_entry; _ } ]; _ } ->
       ()
     | Direct.Quarantined { artifacts; _ } ->
       failf "expected one staging artifact, got %d" (List.length artifacts)
     | Direct.Ready _ -> fail "staging artifact was silently ignored");
    match Direct.inspect_lane ~base_path ~keeper_name:"idealist" |> expect_ok with
    | Direct.Ready [] -> ()
    | Direct.Ready _ -> fail "unrelated lane unexpectedly contained records"
    | Direct.Quarantined _ -> fail "one Keeper quarantine blocked another lane")
;;

let test_codec_and_filename_are_direct_only _env =
  with_temp_dir (fun base_path background_sw ->
    let request_id = request_id "direct-codec" in
    let prepared =
      prepare
        ~background_sw
        ~base_path
        ~request_id
        ~payload:(payload ())
        ~now:1.0
      |> expect_ok
    in
    let path =
      Direct.For_testing.active_path
        ~base_path
        ~keeper_name:"sangsu"
        ~request_id
      |> expect_ok
    in
    check string
      "filename is exactly the canonical request id"
      (Direct.Request_id.to_string request_id)
      (Filename.basename path);
    let json = Direct.For_testing.to_yojson prepared in
    (match json with
     | `Assoc fields ->
       check bool "no delivery_key field" false
         (List.mem_assoc "delivery_key" fields);
       check bool "no receipt field" false (List.mem_assoc "receipt_id" fields);
       let unknown = `Assoc (("legacy_final", `Bool true) :: fields) in
       (match Direct.For_testing.of_yojson unknown with
        | Error (Direct.Decode_failed _) -> ()
        | Error error -> fail (Direct.error_to_string error)
        | Ok _ -> fail "legacy field was accepted");
       let duplicate =
         `Assoc (("request_id", `String "other-direct-codec") :: fields)
       in
       (match Direct.For_testing.of_yojson duplicate with
        | Error (Direct.Decode_failed _) -> ()
        | Error error -> fail (Direct.error_to_string error)
        | Ok _ -> fail "duplicate identity field was accepted")
     | _ -> fail "checkpoint encoder did not produce an object"))
;;

let test_filename_record_identity_mismatch_is_quarantined _env =
  with_temp_dir (fun base_path background_sw ->
    let first_id = request_id "direct-filename-first" in
    let second_id = request_id "direct-filename-second" in
    ignore
      (prepare
         ~background_sw
         ~base_path
         ~request_id:first_id
         ~payload:(payload ())
         ~now:1.0
       |> expect_ok
        : Direct.t);
    let first_path =
      Direct.For_testing.active_path
        ~base_path
        ~keeper_name:"sangsu"
        ~request_id:first_id
      |> expect_ok
    in
    let second_path =
      Direct.For_testing.active_path
        ~base_path
        ~keeper_name:"sangsu"
        ~request_id:second_id
      |> expect_ok
    in
    Fs_compat.save_file second_path (Fs_compat.load_file first_path);
    match Direct.inspect_lane ~base_path ~keeper_name:"sangsu" |> expect_ok with
    | Direct.Quarantined
        { recoverable = [ _ ]
        ; artifacts = [ { reason = Direct.Filename_request_mismatch; _ } ]
        } -> ()
    | Direct.Quarantined { recoverable; artifacts } ->
      failf
        "expected one recoverable record and one mismatch, got records=%d artifacts=%d"
        (List.length recoverable)
        (List.length artifacts)
    | Direct.Ready _ -> fail "filename-to-record mismatch was silently accepted")
;;

let start_settlement ~ops ~background_sw ~base_path ~request_id ~f =
  let settlement, resolve_settlement = Eio.Promise.create () in
  let delivered = Atomic.make false in
  let submitted_request_id =
    Keeper_msg_async.For_testing.submit
      ops
      ~on_worker_settled:(fun ~request_id:_ value ->
        if Atomic.compare_and_set delivered false true
        then Eio.Promise.resolve resolve_settlement value)
      ~background_sw
      ~base_path
      ~caller:"owner"
      ~request:(direct_request "sangsu")
      ~f
      ()
    |> accepted_request_id
  in
  check string
    "async request id is the checkpoint id"
    (Direct.Request_id.to_string request_id)
    submitted_request_id;
  settlement
;;

let await_settlement ~ops ~background_sw ~base_path ~request_id =
  start_settlement
    ~ops
    ~background_sw
    ~base_path
    ~request_id
    ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "completed")
  |> Eio.Promise.await
;;

let expect_durable_done = function
  | Keeper_msg_async.Status_settlement
      { status = Keeper_msg_async.Done _
      ; durability = Keeper_msg_async.Durable
      ; _
      } -> ()
  | _ -> fail "expected a durably committed terminal settlement"
;;

let test_remove_requires_canonical_terminal_proof_and_reports_ambiguity _env =
  with_temp_dir (fun base_path background_sw ->
      let request_id = request_id "direct-remove-proof" in
      let ops =
        Keeper_msg_async.For_testing.make_request_ops
          ~generate_request_id:(fun () -> Direct.Request_id.to_string request_id)
          ()
      in
      let settlement =
        await_settlement ~ops ~background_sw ~base_path ~request_id
      in
      expect_durable_done settlement;
      let flow =
        complete_flow
          ~submit_request:false
          ~background_sw
          ~base_path
          ~request_id
          ()
      in
      (* Model startup after the worker has durably settled: the proof must be
         reconstructible from the exact canonical terminal record alone. *)
      Keeper_msg_async.For_testing.clear ();
      let proof =
        Direct.observe_async_terminal
          ~base_path
          ~identity:flow.transcript_committed
        |> expect_ok
      in
      let remove_io =
        Direct.For_testing.make_io
          ~before_durable_remove:(function
            | Keeper_fs.Parent_directory_fsync ->
              failwith "synthetic post-unlink fsync failure"
            | Keeper_fs.Unlink -> ())
          ()
      in
      (match
         Direct.For_testing.remove_after_async_terminal
           remove_io
           ~base_path
           ~identity:flow.transcript_committed
           ~proof
       with
       | Error (Direct.Removal_failed { removed = true; _ }) -> ()
       | Error error -> fail (Direct.error_to_string error)
       | Ok () -> fail "post-unlink ambiguity was silently reported as success");
      (match Direct.load ~base_path ~keeper_name:"sangsu" ~request_id with
       | Error (Direct.Not_found _) -> ()
       | Error error -> fail (Direct.error_to_string error)
       | Ok _ -> fail "active checkpoint survived an observed unlink");
      let replacement =
        complete_flow
          ~time_offset:10.0
          ~submit_request:false
          ~background_sw
          ~base_path
          ~request_id
          ()
      in
      (match
         Direct.remove_after_async_terminal
           ~base_path
           ~identity:replacement.transcript_committed
           ~proof
       with
       | Error Direct.Async_terminal_identity_mismatch -> ()
       | Error error -> fail (Direct.error_to_string error)
       | Ok () -> fail "terminal proof was replayed against a later checkpoint");
      match Direct.load ~base_path ~keeper_name:"sangsu" ~request_id with
      | Ok checkpoint ->
        check bool
          "replacement checkpoint survives stale proof"
          true
          (Float.equal
             replacement.transcript_committed.created_at
             checkpoint.created_at)
      | Error error -> fail (Direct.error_to_string error))
;;

let test_startup_checkpoint_rejects_volatile_poll_terminal _env =
  with_temp_dir (fun base_path background_sw ->
      let request_id = request_id "direct-volatile-terminal" in
      let publications = Atomic.make 0 in
      let ops =
        Keeper_msg_async.For_testing.make_request_ops
          ~generate_request_id:(fun () -> Direct.Request_id.to_string request_id)
          ~before_durable_write:(fun stage ->
            match stage with
            | Keeper_fs.Parent_directory_fsync_after_rename ->
              let ordinal = Atomic.fetch_and_add publications 1 + 1 in
              if ordinal = 3
              then failwith "synthetic terminal publication ambiguity"
            | Keeper_fs.Directory_prepare
            | Keeper_fs.Payload_encode
            | Keeper_fs.Temp_file_create
            | Keeper_fs.Payload_write
            | Keeper_fs.Payload_fsync
            | Keeper_fs.Temp_file_close
            | Keeper_fs.Atomic_rename
            | Keeper_fs.Temp_directory_fsync_after_rename -> ())
          ()
      in
      let release, resolve_release = Eio.Promise.create () in
      let settlement =
        start_settlement
          ~ops
          ~background_sw
          ~base_path
          ~request_id
          ~f:(fun _request_sw ->
            Eio.Promise.await release;
            Keeper_types_profile.tool_result_ok "completed")
      in
      let flow =
        complete_flow
          ~submit_request:false
          ~background_sw
          ~base_path
          ~request_id
          ()
      in
      Eio.Promise.resolve resolve_release ();
      let settlement = Eio.Promise.await settlement in
      (match settlement with
       | Keeper_msg_async.Status_settlement
           { status = Keeper_msg_async.Done _
           ; durability = Keeper_msg_async.Volatile_persistence_failure
           ; _
           } -> ()
       | _ -> fail "expected a visible terminal with ambiguous durability");
      let request_id_wire = Direct.Request_id.to_string request_id in
      (match Keeper_msg_async.poll ~base_path ~caller:"owner" request_id_wire with
       | Keeper_msg_async.Found { status = Keeper_msg_async.Done _; _ } -> ()
       | _ -> fail "expected volatile poll to expose the typed terminal overlay");
      (match
         Direct.observe_async_terminal
           ~base_path
           ~identity:flow.transcript_committed
       with
       | Error
           (Direct.Async_terminal_rejected
              (Keeper_msg_async.Canonical_terminal_publication_ambiguous
                 (Keeper_msg_async.Done _))) -> ()
       | Error error -> fail (Direct.error_to_string error)
       | Ok _ -> fail "volatile poll terminal was promoted to a durable proof");
      match Direct.load ~base_path ~keeper_name:"sangsu" ~request_id with
      | Ok checkpoint ->
        check int64
          "startup checkpoint remains until canonical durability is proven"
          flow.transcript_committed.revision
          checkpoint.revision
      | Error error -> fail (Direct.error_to_string error))
;;

let test_corrupt_canonical_terminal_is_typed_and_preserved _env =
  with_temp_dir (fun base_path background_sw ->
      let request_id = request_id "direct-corrupt-terminal" in
      let request_id_wire = Direct.Request_id.to_string request_id in
      let ops =
        Keeper_msg_async.For_testing.make_request_ops
          ~generate_request_id:(fun () -> request_id_wire)
          ()
      in
      await_settlement ~ops ~background_sw ~base_path ~request_id
      |> expect_durable_done;
      let flow =
        complete_flow
          ~submit_request:false
          ~background_sw
          ~base_path
          ~request_id
          ()
      in
      Keeper_msg_async.For_testing.clear ();
      let terminal_path =
        match
          Keeper_msg_async.For_testing.terminal_record_path
            ~base_path
            ~request_id:request_id_wire
        with
        | Some path -> path
        | None -> fail "expected a canonical terminal path"
      in
      Fs_compat.save_file terminal_path "{corrupt";
      (match
         Direct.observe_async_terminal
           ~base_path
           ~identity:flow.transcript_committed
       with
       | Error
           (Direct.Async_terminal_rejected
              (Keeper_msg_async.Canonical_terminal_unreadable _)) -> ()
       | Error error -> fail (Direct.error_to_string error)
       | Ok _ -> fail "corrupt canonical terminal produced a durable proof");
      match Direct.load ~base_path ~keeper_name:"sangsu" ~request_id with
      | Ok checkpoint ->
        check int64
          "corrupt async evidence preserves the direct checkpoint"
          flow.transcript_committed.revision
          checkpoint.revision
      | Error error -> fail (Direct.error_to_string error))
;;

let () =
  run
    "keeper_chat_direct_delivery"
    [ ( "direct checkpoint"
      , [ eio_test_case "direct flow remains active-only" `Quick test_direct_flow_is_active_only
        ; eio_test_case
            "canonical request drives the user projection"
            `Quick
            test_canonical_request_drives_user_projection
        ; eio_test_case
            "post-rename ambiguity is explicit and reconcilable"
            `Quick
            test_post_rename_ambiguity_is_reconcilable
        ; eio_test_case
            "transcript append crash retries exactly once"
            `Quick
            test_transcript_append_crash_retries_once
        ; eio_test_case
            "mutation hot path never inventories the lane"
            `Quick
            test_mutations_do_not_inventory_the_lane
        ; eio_test_case
            "quarantine is lane-local and legacy is ignored"
            `Quick
            test_lane_quarantine_is_local_and_legacy_is_ignored
        ; eio_test_case
            "codec and filename are direct-only"
            `Quick
            test_codec_and_filename_are_direct_only
        ; eio_test_case
            "filename and record identity mismatch is quarantined"
            `Quick
            test_filename_record_identity_mismatch_is_quarantined
        ; eio_test_case
            "removal requires canonical durable terminal proof"
            `Quick
            test_remove_requires_canonical_terminal_proof_and_reports_ambiguity
        ; eio_test_case
            "startup checkpoint rejects volatile poll terminal"
            `Quick
            test_startup_checkpoint_rejects_volatile_poll_terminal
        ; eio_test_case
            "corrupt canonical terminal is typed and preserved"
            `Quick
            test_corrupt_canonical_terminal_is_typed_and_preserved
        ] )
    ]
;;
