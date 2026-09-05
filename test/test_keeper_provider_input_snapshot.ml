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

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
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
    (fun _ -> Ok { Agent_core.Types.content = "ok"; _meta = None })
;;

let write config absolute_turn =
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

let read config absolute_turn =
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn in
  match Snapshot.read_resolved ~config ~keeper ~turn_ref with
  | Ok resolved -> resolved
  | Error error ->
    failf "provider input read failed: %s" (Snapshot.read_error_to_string error)
;;

let blob_path store sha256 =
  Filename.concat
    (Filename.concat (Tool_blob_store.root_dir store) (String.sub sha256 0 2))
    sha256
;;

let test_exact_turn_round_trip () =
  with_workspace (fun config ->
    write config 7;
    let resolved = read config 7 in
    check string "keeper" keeper resolved.rv_snapshot.keeper;
    check int "absolute turn" 7 resolved.rv_snapshot.absolute_turn;
    check string
      "turn ref"
      "trace-provider-input#7"
      (Ids.Turn_ref.to_string resolved.rv_snapshot.turn_ref);
    check string "wire provider" "openai-compatible" resolved.rv_snapshot.wire.provider;
    check int "wire bytes" 8192 resolved.rv_snapshot.wire.body_bytes;
    (match resolved.rv_system_prompt with
     | None -> fail "system prompt artifact was not resolved"
     | Some prompt -> check string "system prompt" "exact system prompt" prompt.rsp_text);
    (match resolved.rv_messages with
     | [ message ] ->
       check int "message index" 0 message.rmsg_index;
       check string "message role" "user" message.rmsg_role;
       check bool
         "message content"
         true
         (Yojson.Safe.equal
            (`Assoc
              [ "role", `String "user"
              ; ( "content_blocks"
                , `List
                    [ `Assoc
                        [ "type", `String "text"
                        ; "text", `String "remember exact fact"
                        ]
                    ] )
              ])
            message.rmsg_content)
     | messages -> failf "expected one message, got %d" (List.length messages));
    (match resolved.rv_tool_schemas with
     | [ schema ] ->
       check int "schema index" 0 schema.rts_index;
       check string "schema name" "masc_status" schema.rts_name
     | schemas -> failf "expected one tool schema, got %d" (List.length schemas)))
;;

let test_repeated_history_is_content_deduplicated () =
  with_workspace (fun config ->
    write config 7;
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let first = Tool_blob_store.list_all store |> List.sort String.compare in
    let first_snapshot = read config 7 in
    let snapshot_json =
      Snapshot.to_json first_snapshot.rv_snapshot |> Yojson.Safe.to_string
    in
    check bool
      "snapshot row does not preview the system prompt"
      false
      (String_util.contains_substring snapshot_json "exact system prompt");
    check bool
      "snapshot row does not preview message text"
      false
      (String_util.contains_substring snapshot_json "remember exact fact");
    let prompt_sha =
      match first_snapshot.rv_system_prompt with
      | Some prompt -> prompt.rsp_sha256
      | None -> fail "system prompt artifact was not resolved"
    in
    let prompt_path = blob_path store prompt_sha in
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
    let prompt_sha =
      match first_snapshot.rv_system_prompt with
      | Some prompt -> prompt.rsp_sha256
      | None -> fail "system prompt artifact was not resolved"
    in
    let prompt_path = blob_path store prompt_sha in
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

let test_wrong_turn_is_not_substituted () =
  with_workspace (fun config ->
    write config 7;
    let missing = Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn:8 in
    match Snapshot.read_resolved ~config ~keeper ~turn_ref:missing with
    | Error (Snapshot.Snapshot_not_found actual) ->
      check string
        "missing turn"
        (Ids.Turn_ref.to_string missing)
        (Ids.Turn_ref.to_string actual)
    | Error error ->
      failf "expected Snapshot_not_found, got %s" (Snapshot.read_error_to_string error)
    | Ok _ -> fail "a different turn snapshot was substituted")
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
    Digestif.SHA256.(digest_string bytes |> to_hex)
    payload.Snapshot.payload_sha256
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper provider input snapshot"
    [ ( "round trip"
      , [ test_case "exact turn resolves all artifacts" `Quick test_exact_turn_round_trip
        ; test_case
            "repeated history is content-deduplicated"
            `Quick
            test_repeated_history_is_content_deduplicated
        ; test_case
            "malformed latest snapshot is not reused"
            `Quick
            test_malformed_latest_snapshot_is_not_used_for_reuse
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
        ] )
    ]
;;
