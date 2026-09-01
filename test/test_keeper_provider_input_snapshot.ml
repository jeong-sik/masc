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

let test_exact_turn_round_trip () =
  with_workspace (fun config ->
    write config 7;
    let resolved = read config 7 in
    check string "keeper" keeper resolved.snapshot.keeper;
    check int "absolute turn" 7 resolved.snapshot.absolute_turn;
    check string
      "turn ref"
      "trace-provider-input#7"
      (Ids.Turn_ref.to_string resolved.snapshot.turn_ref);
    check string "wire provider" "openai-compatible" resolved.snapshot.wire.provider;
    check int "wire bytes" 8192 resolved.snapshot.wire.body_bytes;
    (match resolved.resolved_system_prompt with
     | None -> fail "system prompt artifact was not resolved"
     | Some prompt -> check string "system prompt" "exact system prompt" prompt.text);
    (match resolved.resolved_messages with
     | [ message ] ->
       check int "message index" 0 message.index;
       check string "message role" "user" message.role;
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
            message.content)
     | messages -> failf "expected one message, got %d" (List.length messages));
    (match resolved.resolved_tool_schemas with
     | [ schema ] ->
       check int "schema index" 0 schema.index;
       check string "schema name" "masc_status" schema.name
     | schemas -> failf "expected one tool schema, got %d" (List.length schemas)))
;;

let test_repeated_history_is_content_deduplicated () =
  with_workspace (fun config ->
    write config 7;
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let first = Tool_blob_store.list_all store |> List.sort String.compare in
    write config 8;
    let second = Tool_blob_store.list_all store |> List.sort String.compare in
    check (list string) "same content keeps the same artifact set" first second;
    check int "system, message, and schema blobs" 3 (List.length second);
    ignore (read config 7);
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
        ] )
    ; ( "turn boundary"
      , [ test_case
            "a missing turn is not substituted"
            `Quick
            test_wrong_turn_is_not_substituted
        ] )
    ]
;;
