open Alcotest

module Discord_state = Channel_gate_discord_state
module U = Yojson.Safe.Util
module Registry_test_connector_a = struct
  let connector_id = "registry-test-connector"
  let display_name = "Registry Test A"
  let channel = "registry-test"
  let status_json ?(audit_limit = 10) () = ignore audit_limit; `Assoc []
  let connector_json ?(audit_limit = 10) () =
    ignore audit_limit;
    `Assoc
      [ "connector_id", `String connector_id
      ; "display_name", `String display_name
      ]
  let bind ~channel_id:_ ~keeper_name:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "a" ])
  let unbind ~channel_id:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "a" ])
  let unbind_if_keeper ~channel_id:_ ~expected_keeper_name:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "a" ])
  let bound_channels ~keeper_name:_ = Ok []
  let connected () = false
end
module Registry_test_connector_b = struct
  include Registry_test_connector_a

  let display_name = "Registry Test B"
  let connector_json ?(audit_limit = 10) () =
    ignore audit_limit;
    `Assoc
      [ "connector_id", `String connector_id
      ; "display_name", `String display_name
      ]
  let bind ~channel_id:_ ~keeper_name:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "b" ])
end
let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
let temp_dir_counter = ref 0
let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "discord-state-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

let with_discord_paths dir f =
  let binding_path = Filename.concat dir "bindings.json" in
  let audit_path = Filename.concat dir "audit.jsonl" in
  with_env "MASC_DISCORD_BINDING_STORE_PATH" (Some binding_path) (fun () ->
    with_env "MASC_DISCORD_BINDING_AUDIT_PATH" (Some audit_path) f)

let test_bot_token_accessor_unset_and_whitespace () =
  (* The supported OCaml 5.4 test runtime has no [Unix.unsetenv]; the
     existing [with_env ... None] helper represents an unset variable with
     an empty value, which the accessor must treat as absent. *)
  with_env "DISCORD_BOT_TOKEN" None (fun () ->
    check (option string) "unset token -> None" None
      (Env_config_discord.bot_token_opt ()));
  with_env "DISCORD_BOT_TOKEN" (Some " \t \n ") (fun () ->
    check (option string) "whitespace-only token -> None" None
      (Env_config_discord.bot_token_opt ()))

let test_bot_token_accessor_trims_and_feeds_status_consumer () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" (Some "  token-42 \t ") (fun () ->
    check (option string) "surrounding whitespace is trimmed" (Some "token-42")
      (Env_config_discord.bot_token_opt ());
    let json = Discord_state.status_json () in
    check bool "trimmed token enables disconnected transport" true
      (json |> U.member "available" |> U.to_bool);
    check string "trimmed token has no missing-token error" ""
      (json |> U.member "error" |> U.to_string)))

let test_status_json_reports_in_process_gateway_status () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" None (fun () ->
    let json = Discord_state.status_json () in
    check string "channel" "discord"
      (json |> U.member "channel" |> U.to_string);
    check bool "available false" false
      (json |> U.member "available" |> U.to_bool);
    check bool "connected false" false
      (json |> U.member "connected" |> U.to_bool);
    check string "status source" "in_process_gateway"
      (json |> U.member "status_source" |> U.to_string);
    check string "gateway state" "disconnected"
      (json |> U.member "gateway_state" |> U.to_string);
    check string "missing-token error" "DISCORD_BOT_TOKEN is unset or empty"
      (json |> U.member "error" |> U.to_string);
    check int "no configured bindings" 0
      (json |> U.member "configured_bindings" |> U.to_list |> List.length)))

let test_status_json_surfaces_binding_store_failure () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" (Some "token") (fun () ->
    Fs_compat.save_file (Filename.concat dir "bindings.json") "{not-json";
    let json = Discord_state.status_json () in
    check bool "routing unavailable" false
      (json |> U.member "available" |> U.to_bool);
    check bool "binding store read failed" false
      (json |> U.member "binding_store_read_ok" |> U.to_bool);
    check bool "binding store error is explicit" true
      (json |> U.member "binding_store_error" |> U.to_string |> String.length
       |> fun length -> length > 0);
    check bool "connector error includes binding failure" true
      (json |> U.member "error" |> U.to_string |> String.length
       |> fun length -> length > 0)))

(* record_ready ordering: this test runs in the same process as the
   blank-identity assertions above, so it must come after them in the
   suite — last_ready is module-global and has no reset (production
   never clears it; a fresh READY only overwrites). *)
let test_record_ready_surfaces_bot_identity () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" None (fun () ->
    Discord_state.record_ready ~bot_user_id:"bot-42"
      ~bot_user_name:(Some "MASC Bot") ~guild_ids:[ "guild-1"; "guild-2" ];
    Discord_state.record_directory_refresh_finished ~server_count:2
      ~channel_count:12 ~person_count:34
      ~authentication_failed:[]
      ~permission_denied:[ "members" ] ~errors:[];
    let json = Discord_state.status_json () in
    check string "bot_user_id from READY" "bot-42"
      (json |> U.member "bot_user_id" |> U.to_string);
    check string "bot_user_name from READY" "MASC Bot"
      (json |> U.member "bot_user_name" |> U.to_string);
    check int "guild count from READY" 2
      (json |> U.member "guild_count" |> U.to_int);
    check string "partial directory state" "partial"
      (json |> U.member "directory_state" |> U.to_string);
    check int "directory people count" 34
      (json |> U.member "directory_person_count" |> U.to_int);
    check bool "last_ready_at non-empty" true
      (String.length (json |> U.member "last_ready_at" |> U.to_string) > 0);
    (* Identity is observation, not liveness: gateway is still down. *)
    check bool "connected stays false" false
      (json |> U.member "connected" |> U.to_bool)))

let test_bind_persists_binding_and_audit () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    match
      Discord_state.bind ~channel_id:"1234567890" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        let bindings = json |> U.member "configured_bindings" |> U.to_list in
        check int "one configured binding" 1 (List.length bindings);
        check string "keeper persisted" "luna"
          (List.hd bindings |> U.member "keeper_name" |> U.to_string);
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check int "one audit event" 1 (List.length audit);
        check string "audit actor" "dashboard"
          (List.hd audit |> U.member "actor_name" |> U.to_string);
        (match Discord_state.configured_channel_ids_result () with
         | Ok channel_ids ->
           check (list string) "directory refresh scope"
             [ "1234567890" ] channel_ids
         | Error error ->
           fail (Discord_state.binding_lookup_error_to_string error)))

let test_unbind_removes_existing_binding () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    ignore
      (Discord_state.bind ~channel_id:"1234567890" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    match
      Discord_state.unbind ~channel_id:"1234567890" ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        check int "bindings cleared" 0
          (json |> U.member "configured_bindings" |> U.to_list |> List.length);
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check int "two audit events" 2 (List.length audit);
        check string "latest audit action" "unbind"
          (List.hd audit |> U.member "action" |> U.to_string))

let test_conditional_unbind_preserves_reassigned_binding () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    ignore
      (Discord_state.bind ~channel_id:"1234567890" ~keeper_name:"new-owner"
         ~actor_name:"dashboard");
    (match
       Discord_state.unbind_if_keeper ~channel_id:"1234567890"
         ~expected_keeper_name:"old-owner" ~actor_name:"dashboard"
     with
     | Error "binding changed" -> ()
     | Error detail -> fail ("unexpected conditional-unbind error: " ^ detail)
     | Ok _ -> fail "conditional unbind removed a reassigned binding");
    match Discord_state.keeper_for_channel_result ~channel_id:"1234567890" with
    | Ok (Some keeper_name) ->
      check string "reassigned owner remains" "new-owner" keeper_name
    | Ok None -> fail "conditional unbind removed the binding"
    | Error detail -> fail (Discord_state.binding_lookup_error_to_string detail))

let test_connectors_json_advertises_gate_connector_descriptor () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_state.set_trigger_policy Discord_gateway_state.All;
    ignore
      (Discord_state.bind ~channel_id:"1234567890" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    Channel_gate_connector.register (module Discord_state);
    let json = Channel_gate_connector.connectors_json () in
    let connectors = json |> U.member "connectors" |> U.to_list in
    check int "one connector" 1 (List.length connectors);
    let connector = List.hd connectors in
    check string "connector id" "discord"
      (connector |> U.member "connector_id" |> U.to_string);
    check string "display name" "Discord"
      (connector |> U.member "display_name" |> U.to_string);
    check string "leaf trigger policy" "all"
      (connector |> U.member "trigger_policy" |> U.to_string);
    (match json with
     | `Assoc fields ->
       check bool "aggregate has no Discord-specific field" false
         (List.mem_assoc "discord_trigger_policy" fields)
     | _ -> fail "expected connector aggregate object");
    check bool "bindings capability exposed" true
      (connector |> U.member "capabilities" |> U.to_list
       |> List.exists (function
            | `String "bindings" -> true
            | _ -> false));
    check string "status source surfaced" "in_process_gateway"
      (connector |> U.member "status_source" |> U.to_string);
    check bool "gateway state surfaced" true
      (connector |> U.member "gateway_state" |> U.to_string
       |> String.trim |> String.length > 0))

let test_registry_register_replaces_and_all_snapshots () =
  Channel_gate_connector.register (module Registry_test_connector_a);
  (match Channel_gate_connector.find Registry_test_connector_a.connector_id with
   | None -> fail "expected initial registry test connector"
   | Some (module C : Channel_gate_connector.S) ->
     check string "initial connector" "Registry Test A" C.display_name);
  Channel_gate_connector.register (module Registry_test_connector_b);
  (match Channel_gate_connector.find Registry_test_connector_a.connector_id with
   | None -> fail "expected replacement registry test connector"
   | Some (module C : Channel_gate_connector.S) ->
     check string "replacement connector" "Registry Test B" C.display_name);
  let registered =
    Channel_gate_connector.all ()
    |> List.filter (fun (module C : Channel_gate_connector.S) ->
      String.equal C.connector_id Registry_test_connector_a.connector_id)
  in
  check int "single connector id after replace" 1 (List.length registered);
  match registered with
  | [ (module C : Channel_gate_connector.S) ] ->
    check string "snapshot sees replacement" "Registry Test B" C.display_name
  | _ -> fail "unexpected registry snapshot"

(* The audit wire shape keeps a constant-empty [guild_id] key for Discord
   rows: dashboards read that shape, and the sidecar that once resolved
   real guild ids is gone. *)
let test_bind_audit_carries_constant_empty_guild_id () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    match
      Discord_state.bind ~channel_id:"unknown" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check string "audit guild_id stays empty" ""
          (List.hd audit |> U.member "guild_id" |> U.to_string))

let test_resolve_keeper_for_thread_parent_binding () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    ignore
      (Discord_state.bind ~channel_id:"parent-1" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    Discord_state.register_thread
      ~thread_id:"thread-1"
      ~parent_channel_id:"parent-1";
    match
      Discord_state.resolve_keeper_for_channel_result ~channel_id:"thread-1"
    with
    | Error _ | Ok None -> fail "expected registered parent binding to resolve"
    | Ok (Some resolution) ->
        check string "keeper" "luna" resolution.keeper_name;
        check string "incoming" "thread-1" resolution.incoming_channel_id;
        check string "bound" "parent-1" resolution.bound_channel_id;
        check bool "via parent" true resolution.via_parent)

let test_resolve_keeper_exact_binding_wins_over_parent () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    ignore
      (Discord_state.bind ~channel_id:"parent-1" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    ignore
      (Discord_state.bind ~channel_id:"thread-1" ~keeper_name:"alpha"
         ~actor_name:"dashboard");
    match
      Discord_state.resolve_keeper_for_channel_result ~channel_id:"thread-1"
    with
    | Error _ | Ok None -> fail "expected exact binding to resolve"
    | Ok (Some resolution) ->
        check string "keeper" "alpha" resolution.keeper_name;
        check string "incoming" "thread-1" resolution.incoming_channel_id;
        check string "bound" "thread-1" resolution.bound_channel_id;
        check bool "not via parent" false resolution.via_parent)

let test_binding_store_failures_are_not_empty_state () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Fs_compat.save_file (Filename.concat dir "bindings.json") "{not-json";
    let expect_error label = function
      | Error _ -> ()
      | Ok _ -> fail label
    in
    Discord_state.resolve_keeper_for_channel_result ~channel_id:"channel-1"
    |> expect_error "lookup reduced malformed store to unbound";
    Discord_state.bind ~channel_id:"channel-1" ~keeper_name:"luna"
      ~actor_name:"dashboard"
    |> expect_error "bind overwrote malformed store";
    Discord_state.unbind ~channel_id:"channel-1" ~actor_name:"dashboard"
    |> expect_error "unbind overwrote malformed store";
    Discord_state.bound_channels_result ~keeper_name:"luna"
    |> expect_error "presence reduced malformed store to empty")

let test_thread_registry_round_trip () =
  let suffix = Printf.sprintf "%d-%06d" (Unix.getpid ()) !temp_dir_counter in
  let thread_id = "thread-registry-" ^ suffix in
  let parent_id = "parent-registry-" ^ suffix in
  let parent_id_2 = parent_id ^ "-updated" in
  Discord_state.unregister_thread ~thread_id;
  let before = Discord_state.registered_thread_count () in
  Discord_state.register_thread
    ~thread_id:("  " ^ thread_id ^ "  ")
    ~parent_channel_id:("  " ^ parent_id ^ "  ");
  check int "count increments" (before + 1)
    (Discord_state.registered_thread_count ());
  check (option string) "parent lookup trims channel" (Some parent_id)
    (Discord_state.parent_channel_of_thread ~channel_id:(" " ^ thread_id));
  check bool "known thread" true
    (Discord_state.is_known_thread ~channel_id:thread_id);
  Discord_state.register_thread ~thread_id ~parent_channel_id:parent_id_2;
  check int "duplicate update keeps count" (before + 1)
    (Discord_state.registered_thread_count ());
  check (option string) "duplicate update replaces parent" (Some parent_id_2)
    (Discord_state.parent_channel_of_thread ~channel_id:thread_id);
  Discord_state.register_thread ~thread_id:"  " ~parent_channel_id:"ignored";
  check int "blank thread id ignored" (before + 1)
    (Discord_state.registered_thread_count ());
  Discord_state.unregister_thread ~thread_id:(" " ^ thread_id ^ " ");
  check (option string) "parent removed" None
    (Discord_state.parent_channel_of_thread ~channel_id:thread_id);
  check bool "known removed" false
    (Discord_state.is_known_thread ~channel_id:thread_id);
  check int "count restored" before (Discord_state.registered_thread_count ())

let test_large_mention_allowlist_keeps_tokens_whole () =
  let user_ids =
    List.init 100 (fun index -> Printf.sprintf "12345678901234%04d" index)
  in
  let messages =
    Discord_state.For_testing.message_chunks_with_mentions
      ~limit:2000
      ~content:"body"
      ~mention_user_ids:user_ids
  in
  check bool "large allowlist uses multiple messages" true
    (List.length messages > 1);
  check (list string) "every allowed id is retained exactly once" user_ids
    (List.concat_map
       (fun (message : Discord_state.For_testing.outbound_message) ->
          message.allowed_user_mentions)
       messages);
  List.iter
    (fun (message : Discord_state.For_testing.outbound_message) ->
       check bool "message remains within Discord limit" true
         (String.length message.content <= 2000);
       List.iter
         (fun user_id ->
            check bool "allowed mention has a complete visible token" true
              (String_util.contains_substring
                 message.content
                 (Printf.sprintf "<@%s>" user_id)))
         message.allowed_user_mentions)
    messages;
  match List.rev messages with
  | last :: _ ->
    check string "content is delivered after mention groups" "body" last.content;
    check (list string) "content does not reopen mentions" []
      last.allowed_user_mentions
  | [] -> fail "mention chunker produced no messages"

let () =
  Eio_main.run @@ fun _env ->
  run "channel_gate_discord_state"
    [
      ( "status",
        [
          test_case "bot token accessor handles unset and whitespace" `Quick
            test_bot_token_accessor_unset_and_whitespace;
          test_case "bot token accessor trims for status consumer" `Quick
            test_bot_token_accessor_trims_and_feeds_status_consumer;
          test_case "in-process gateway status" `Quick
            test_status_json_reports_in_process_gateway_status;
          test_case "surfaces binding store failure" `Quick
            test_status_json_surfaces_binding_store_failure;
          test_case "record_ready surfaces bot identity" `Quick
            test_record_ready_surfaces_bot_identity;
          test_case "bind persists binding and audit" `Quick
            test_bind_persists_binding_and_audit;
          test_case "unbind removes binding" `Quick
            test_unbind_removes_existing_binding;
          test_case "conditional unbind preserves reassigned binding" `Quick
            test_conditional_unbind_preserves_reassigned_binding;
          test_case "binding-store failures remain explicit" `Quick
            test_binding_store_failures_are_not_empty_state;
          test_case "connectors json advertises connector descriptor" `Quick
            test_connectors_json_advertises_gate_connector_descriptor;
          test_case "registry register replaces and all snapshots" `Quick
            test_registry_register_replaces_and_all_snapshots;
        ] );
      ( "audit_wire",
        [
          test_case "bind audit carries constant-empty guild_id" `Quick
            test_bind_audit_carries_constant_empty_guild_id;
          test_case "thread resolves through parent binding" `Quick
            test_resolve_keeper_for_thread_parent_binding;
          test_case "exact binding wins over parent" `Quick
            test_resolve_keeper_exact_binding_wins_over_parent;
        ] );
      ( "thread_registry",
        [
          test_case "register lookup update unregister" `Quick
            test_thread_registry_round_trip;
        ] );
      ( "message_chunks",
        [
          test_case "large mention allowlist keeps tokens whole" `Quick
            test_large_mention_allowlist_keeps_tokens_whole;
        ] );
    ]
