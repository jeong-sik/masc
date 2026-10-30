open Alcotest
open Masc

module Snapshot = Keeper_provider_input_snapshot
module Wire = Llm_provider.Request_wire_observer

let keeper = "provider-input-fixture"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-provider-input-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    (try Unix.rmdir path with
     | Unix.Unix_error _ -> ())
  | _ ->
    (try Unix.unlink path with
     | Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

let with_workspace_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f env sw config
;;

let with_workspace f =
  with_workspace_env (fun _env _sw config -> f config)
;;

let wire : Wire.observation =
  { phase = Wire.Pre_dispatch_serialization
  ; capture_id = Some "capture-fixture"
  ; provider = "openai-compatible"
  ; model = "fixture-model"
  ; http_codec = "responses"
  ; stream = true
  ; body_bytes = 8192
  ; body_sha256 = String.make 64 'a'
  }
;;

let message = Agent_core.Types.text_message Agent_core.Types.User "remember exact fact"

let tool =
  Agent_core.Tool.create
    ~name:"masc_status"
    ~description:"read current status"
    ~parameters:[]
    (fun _ -> Ok { Agent_core.Types.content = "ok"; content_blocks = None; _meta = None })
;;

let write_for config keeper absolute_turn =
  Snapshot.write_best_effort
    ~config
    ~keeper
    ~trace_id:"trace-provider-input"
    ~absolute_turn
    ~runtime_profile:"local"
    ~wire
    ~system_prompt:"exact system prompt"
    ~messages:[ message ]
    ~tools:[ tool ]
;;

let write config absolute_turn = write_for config keeper absolute_turn

let turn_ref absolute_turn =
  Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn
;;

let read_for config keeper absolute_turn =
  match Snapshot.read_manifest ~config ~keeper ~turn_ref:(turn_ref absolute_turn) with
  | Ok manifest -> manifest
  | Error error ->
    failf "provider input read failed: %s" (Snapshot.read_error_to_string error)
;;

let read config absolute_turn = read_for config keeper absolute_turn

let read_part config absolute_turn index =
  Snapshot.read_part ~config ~keeper ~turn_ref:(turn_ref absolute_turn) ~index
;;

let prompt_sha (manifest : Snapshot.manifest) =
  match manifest.mf_parts with
  | { part_kind = Snapshot.System_prompt; part_sha256; _ } :: _ -> part_sha256
  | _ -> fail "the system prompt is not the first part"
;;

let blob_path store sha256 =
  Filename.concat
    (Filename.concat (Tool_blob_store.root_dir store) (String.sub sha256 0 2))
    sha256
;;

let test_exact_turn_round_trip () =
  with_workspace (fun config ->
    write config 7;
    let manifest = read config 7 in
    check string "keeper" keeper manifest.mf_snapshot.keeper;
    check int "absolute turn" 7 manifest.mf_snapshot.absolute_turn;
    check string
      "turn ref"
      "trace-provider-input#7"
      (Ids.Turn_ref.to_string manifest.mf_snapshot.turn_ref);
    check string "wire provider" "openai-compatible" manifest.mf_snapshot.wire.provider;
    check int "wire bytes" 8192 manifest.mf_snapshot.wire.body_bytes;
    (match manifest.mf_parts with
     | [ { part_index = 0; part_kind = Snapshot.System_prompt; _ }
       ; { part_index = 1; part_kind = Snapshot.Message { role = "user" }; _ }
       ; { part_index = 2; part_kind = Snapshot.Tool_schema { name = "masc_status" }; _ }
       ] -> ()
     | parts -> failf "expected prompt, message, schema; got %d parts" (List.length parts));
    List.iter
      (fun (part : Snapshot.part) ->
         match read_part config 7 part.part_index with
         | Error error ->
           failf "part %d read failed: %s" part.part_index
             (Snapshot.read_error_to_string error)
         | Ok content ->
           check bool "the part read is the part listed" true (content.pc_part = part);
           check int "bytes" part.part_bytes (String.length content.pc_text);
           check string "sha256 of the bytes" part.part_sha256
             Agent_core_sha256.(digest_string content.pc_text |> to_hex))
      manifest.mf_parts;
    (match read_part config 7 0 with
     | Ok content -> check string "system prompt" "exact system prompt" content.pc_text
     | Error error -> failf "%s" (Snapshot.read_error_to_string error));
    match read_part config 7 1 with
    | Ok content ->
      check bool
        "message bytes are the serialised message"
        true
        (Yojson.Safe.equal
           (`Assoc
             [ "role", `String "user"
             ; "origin", `String "conversation"
             ; ( "content_blocks"
               , `List
                   [ `Assoc
                       [ "type", `String "text"
                       ; "text", `String "remember exact fact"
                       ]
                   ] )
             ])
           (Yojson.Safe.from_string content.pc_text))
    | Error error -> failf "%s" (Snapshot.read_error_to_string error))
;;

let test_shared_pool_and_nested_worker_round_trip () =
  with_workspace_env (fun env sw config ->
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    let previous = Domain_pool_ref.get () in
    Domain_pool_ref.set pool;
    let restore_pool () =
      match previous with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous
    in
    Fun.protect ~finally:restore_pool (fun () ->
      let check_turn absolute_turn expected_prompt =
        let manifest = read config absolute_turn in
        check int "all parts retained" 3 (List.length manifest.mf_parts);
        List.iter
          (fun (part : Snapshot.part) ->
             match read_part config absolute_turn part.part_index with
             | Error error -> failf "%s" (Snapshot.read_error_to_string error)
             | Ok content ->
               check int "part byte count" part.part_bytes (String.length content.pc_text);
               check string "part digest" part.part_sha256
                 Agent_core_sha256.(digest_string content.pc_text |> to_hex);
               if part.part_index = 0 then
                 check string "system prompt" expected_prompt content.pc_text)
          manifest.mf_parts
      in
      write config 7;
      check_turn 7 "exact system prompt";
      let caller_domain = (Domain.self () :> int) in
      (* Occupy the one worker's full capacity. Both snapshot pool adapters
         must run inline here instead of submitting back to that worker. *)
      Domain_pool.submit_cpu ~name:__FUNCTION__ pool (fun () ->
        check bool "the enclosing job runs on the worker" true
          ((Domain.self () :> int) <> caller_domain);
        Snapshot.write_best_effort
          ~config
          ~keeper
          ~trace_id:"trace-provider-input"
          ~absolute_turn:8
          ~runtime_profile:"local"
          ~wire
          ~system_prompt:"new prompt from the worker"
          ~messages:[ message ]
          ~tools:[ tool ]);
      check_turn 8 "new prompt from the worker"))
;;

(* The list answers from the row alone. With every blob gone the parts are
   still listed, and only reading a part reports the absent blob. *)
let test_the_list_reads_no_blob () =
  with_workspace (fun config ->
    write config 7;
    let store = Tool_blob_store.create ~base_path:config.base_path in
    List.iter
      (fun sha256 -> Sys.remove (blob_path store sha256))
      (Tool_blob_store.list_all store);
    check int "parts listed" 3 (List.length (read config 7).mf_parts);
    match read_part config 7 0 with
    | Error (Snapshot.Artifact_missing _) -> ()
    | Error error ->
      failf "expected Artifact_missing, got %s" (Snapshot.read_error_to_string error)
    | Ok _ -> fail "a removed blob was read")
;;

let test_a_part_the_row_does_not_list_is_refused () =
  with_workspace (fun config ->
    write config 7;
    List.iter
      (fun index ->
         match read_part config 7 index with
         | Error (Snapshot.Part_not_found { index = refused; _ }) ->
           check int "the index asked for is refused" index refused
         | Error error ->
           failf "expected Part_not_found, got %s" (Snapshot.read_error_to_string error)
         | Ok _ -> failf "part %d was read from a row that lists 3" index)
      [ 3; -1 ])
;;

let test_repeated_history_is_content_deduplicated () =
  with_workspace (fun config ->
    write config 7;
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let first = Tool_blob_store.list_all store |> List.sort String.compare in
    let first_snapshot = read config 7 in
    let snapshot_json =
      Snapshot.to_json first_snapshot.mf_snapshot |> Yojson.Safe.to_string
    in
    check bool
      "snapshot row does not preview the system prompt"
      false
      (String_util.contains_substring snapshot_json "exact system prompt");
    check bool
      "snapshot row does not preview message text"
      false
      (String_util.contains_substring snapshot_json "remember exact fact");
    let prompt_path = blob_path store (prompt_sha first_snapshot) in
    let sentinel_mtime = 1_500_000_000. in
    Unix.utimes prompt_path sentinel_mtime sentinel_mtime;
    write config 8;
    let second = Tool_blob_store.list_all store |> List.sort String.compare in
    check (list string) "same content keeps the same artifact set" first second;
    check int "system, message, and schema blobs" 3 (List.length second);
    check (float 0.001)
      "a repeated artifact is not rewritten"
      sentinel_mtime
      (Unix.stat prompt_path).st_mtime;
    ignore (read config 7);
    ignore (read config 8))
;;

let test_malformed_latest_snapshot_is_not_used_for_reuse () =
  with_workspace (fun config ->
    write config 7;
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let first_snapshot = read config 7 in
    let prompt_path = blob_path store (prompt_sha first_snapshot) in
    let sentinel_mtime = 1_500_000_000. in
    Unix.utimes prompt_path sentinel_mtime sentinel_mtime;
    Dated_jsonl.append
      (Keeper_types_support.keeper_provider_input_store config keeper)
      (`Assoc [ "schema", `String "broken" ]);
    write config 8;
    check bool
      "malformed newest row forces a fresh durable write"
      true
      (Float.abs ((Unix.stat prompt_path).st_mtime -. sentinel_mtime) > 0.001);
    ignore (read config 8))
;;

let test_new_owner_and_malformed_history_reuse_verified_blobs () =
  with_workspace_env (fun _env sw config ->
    write config 7;
    let first = read config 7 in
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let originals =
      List.map
        (fun (part : Snapshot.part) ->
          let path = blob_path store part.part_sha256 in
          let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
          Eio.Switch.on_release sw (fun () -> Unix.close fd);
          path, Unix.fstat fd)
        first.mf_parts
    in
    let check_originals () =
      List.iter
        (fun (path, before) ->
          let after = Unix.stat path in
          check bool "verified physical blob is retained" true
            (before.Unix.st_dev = after.Unix.st_dev
             && before.Unix.st_ino = after.Unix.st_ino))
        originals
    in
    let other = "provider-input-other-owner" in
    (* This owner has no previous snapshot from which to borrow a reuse map. *)
    write_for config other 7;
    check bool "another owner retains the exact ordered parts" true
      (first.mf_parts = (read_for config other 7).mf_parts);
    check_originals ();
    (* Invalid owner history supplies no authority. The unchanged physical
       blobs still have their separate strict-publication evidence. *)
    Dated_jsonl.append
      (Keeper_types_support.keeper_provider_input_store config keeper)
      (`Assoc [ "schema", `String "broken" ]);
    write config 8;
    check bool "malformed history does not alter the new exact parts" true
      (first.mf_parts = (read config 8).mf_parts);
    check_originals ())
;;

let test_new_owner_repairs_missing_corrupt_and_nonstrict_blobs () =
  with_workspace_env (fun _env sw config ->
    write config 7;
    let first = read config 7 in
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let parts = Array.of_list first.mf_parts in
    let path index = blob_path store parts.(index).part_sha256 in
    let exact_contents =
      Array.init 3 (fun index ->
        match read_part config 7 index with
        | Ok content -> content.pc_text
        | Error error -> failf "%s" (Snapshot.read_error_to_string error))
    in
    Unix.unlink (path 0);
    Fs_compat.save_file (path 1) "corrupt provider message";
    ignore
      (Tool_blob_store.put store ~bytes:exact_contents.(2) ~mime:"application/json"
        : Tool_output.t);
    let ordinary_fd = Unix.openfile (path 2) [ Unix.O_RDONLY ] 0 in
    Eio.Switch.on_release sw (fun () -> Unix.close ordinary_fd);
    let ordinary_identity = Unix.fstat ordinary_fd in
    let other = "provider-input-repair-owner" in
    write_for config other 7;
    let repaired = read_for config other 7 in
    check bool "fresh owner retains all exact original parts" true
      (first.mf_parts = repaired.mf_parts);
    List.iter
      (fun (part : Snapshot.part) ->
        match Snapshot.read_part ~config ~keeper:other ~turn_ref:(turn_ref 7)
          ~index:part.part_index with
        | Error error -> failf "%s" (Snapshot.read_error_to_string error)
        | Ok content ->
          check string "damaged or missing bytes are restored exactly"
            exact_contents.(part.part_index) content.pc_text)
      repaired.mf_parts;
    let strict_identity = Unix.stat (path 2) in
    check bool "ordinary replacement cannot inherit strict publication" true
      (ordinary_identity.Unix.st_dev <> strict_identity.Unix.st_dev
       || ordinary_identity.Unix.st_ino <> strict_identity.Unix.st_ino))
;;

let test_wrong_turn_is_not_substituted () =
  with_workspace (fun config ->
    write config 7;
    let missing = Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn:8 in
    match Snapshot.read_manifest ~config ~keeper ~turn_ref:missing with
    | Error (Snapshot.Snapshot_not_found actual) ->
      check string
        "missing turn"
        (Ids.Turn_ref.to_string missing)
        (Ids.Turn_ref.to_string actual)
    | Error error ->
      failf "expected Snapshot_not_found, got %s" (Snapshot.read_error_to_string error)
    | Ok _ -> fail "a different turn snapshot was substituted")
;;

(* The scan reads the store newest first. A live store is 79-231 MB of
   snapshots, and reading past the turn asked for decodes every one of them to
   answer a question the order already settles. The unreadable oldest row is
   the proof: a scan that reaches it reports that row instead of the missing
   turn. *)
let test_a_scan_stops_at_an_older_turn_of_the_same_trace () =
  with_workspace (fun config ->
    let store = Keeper_types_support.keeper_provider_input_store config keeper in
    Dated_jsonl.append store (`Assoc [ "schema", `String "broken" ]);
    write config 5;
    write config 6;
    let missing = Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn:9 in
    (match Snapshot.read_manifest ~config ~keeper ~turn_ref:missing with
     | Error (Snapshot.Snapshot_not_found actual) ->
       check string
         "the turn asked for is the one reported missing"
         (Ids.Turn_ref.to_string missing)
         (Ids.Turn_ref.to_string actual)
     | Error error ->
       failf
         "the scan read past the newest turn: %s"
         (Snapshot.read_error_to_string error)
     | Ok _ -> fail "a different turn snapshot was substituted");
    ignore (read config 5))
;;

(* Another trace's turn numbers say nothing about this trace's, so a lower
   turn under a different trace must not end the scan. *)
let test_another_trace_does_not_end_the_scan () =
  with_workspace (fun config ->
    write config 5;
    Snapshot.write_best_effort
      ~config
      ~keeper
      ~trace_id:"trace-provider-input-restarted"
      ~absolute_turn:1
      ~runtime_profile:"local"
      ~wire
      ~system_prompt:"exact system prompt"
      ~messages:[ message ]
      ~tools:[ tool ];
    let wanted = Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn:5 in
    match Snapshot.read_manifest ~config ~keeper ~turn_ref:wanted with
    | Ok manifest ->
      check string
        "the older trace's turn is still found"
        (Ids.Turn_ref.to_string wanted)
        (Ids.Turn_ref.to_string manifest.mf_snapshot.turn_ref)
    | Error error ->
      failf "the scan stopped too early: %s" (Snapshot.read_error_to_string error))
;;

(* A snapshot message blob names its media by reference, and blob retention
   does not read message blobs. The row lists the references, so an image
   named by a retained snapshot alone survives two deleting sweeps. *)
let test_a_snapshot_keeps_its_history_media_live () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let media_store = Tool_blob_media_store.of_base_path ~base_path in
    let raw = "provider input image" in
    let stored =
      match media_store.put ~media_type:"image/png" ~raw with
      | Ok stored -> stored
      | Error error -> failf "put: %s" (Agent_core.Error.to_string (Agent_core.Error.Media error))
    in
    let image_message =
      Agent_core.Types.user_msg_blocks
        [ Agent_core.Types.Image
            { media_type = "image/png"; source = Agent_core.Types.Stored stored }
        ]
    in
    Snapshot.write_best_effort ~config ~keeper ~trace_id:"trace-provider-input"
      ~absolute_turn:1 ~runtime_profile:"local" ~wire ~system_prompt:""
      ~messages:[ image_message ] ~tools:[];
    let manifest = read_for config keeper 1 in
    (match manifest.Snapshot.mf_snapshot.messages with
     | [ { Snapshot.msg_media = [ ("image/png", listed) ]; _ } ] ->
       check bool "the row lists the stored image" true (listed = stored)
     | _ -> fail "the snapshot row must list the message's stored media");
    for _pass = 1 to 2 do
      match
        Tool_blob_maintenance.run ~base_path
          ~board_posts_file:Masc_board_handlers.Board_paths.posts_file
          ~mode:Tool_blob_maintenance.Delete_previous_candidates
      with
      | Ok _ -> ()
      | Error error -> failf "maintenance: %s" (Tool_blob_maintenance.error_to_string error)
    done;
    check bool "the snapshot image survives" true (media_store.get stored = Ok raw))
;;

let test_message_payload_matches_the_serialised_message () =
  let bytes =
    Keeper_context_core_message_json.message_to_json message |> Yojson.Safe.to_string
  in
  let payload = Snapshot.message_payload message in
  check string "bytes are the serialised message" bytes payload.Snapshot.payload_bytes;
  check
    string
    "digest is the sha256 of those bytes"
    Agent_core_sha256.(digest_string bytes |> to_hex)
    payload.Snapshot.payload_sha256
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper provider input snapshot"
    [ ( "round trip"
      , [ test_case "exact turn lists and reads every part" `Quick test_exact_turn_round_trip
        ; test_case
            "shared pool and nested worker preserve exact parts"
            `Quick
            test_shared_pool_and_nested_worker_round_trip
        ; test_case "a snapshot keeps its history media live" `Quick
          test_a_snapshot_keeps_its_history_media_live
        ; test_case "the list reads no blob" `Quick test_the_list_reads_no_blob
        ; test_case
            "a part the row does not list is refused"
            `Quick
            test_a_part_the_row_does_not_list_is_refused
        ; test_case
            "repeated history is content-deduplicated"
            `Quick
            test_repeated_history_is_content_deduplicated
        ; test_case
            "malformed latest snapshot is not reused"
            `Quick
            test_malformed_latest_snapshot_is_not_used_for_reuse
        ; test_case
            "new owners and malformed history reuse verified physical blobs"
            `Quick
            test_new_owner_and_malformed_history_reuse_verified_blobs
        ; test_case
            "new owners repair missing, corrupt and non-strict blobs"
            `Quick
            test_new_owner_repairs_missing_corrupt_and_nonstrict_blobs
        ; test_case
            "a message payload is the serialised message and its digest"
            `Quick
            test_message_payload_matches_the_serialised_message
        ] )
    ; ( "turn boundary"
      , [ test_case
            "a missing turn is not substituted"
            `Quick
            test_wrong_turn_is_not_substituted
        ; test_case
            "a scan stops at an older turn of the same trace"
            `Quick
            test_a_scan_stops_at_an_older_turn_of_the_same_trace
        ; test_case
            "another trace's turn does not end the scan"
            `Quick
            test_another_trace_does_not_end_the_scan
        ] )
    ]
;;
