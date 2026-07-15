open Alcotest

module Discord_state = Channel_gate_discord_state
module Discord_names = Channel_gate_discord_names
module U = Yojson.Safe.Util

module Registry_test_connector_a = struct
  let connector_id = "registry-test-connector"
  let display_name = "Registry Test A"
  let channel = "registry-test"
  let status_json ?(audit_limit = 10) () = ignore audit_limit; `Assoc []
  let connector_json ?gate_status_json ?(audit_limit = 10) () =
    ignore gate_status_json;
    ignore audit_limit;
    `Assoc
      [ "connector_id", `String connector_id
      ; "display_name", `String display_name
      ]
  let bind ~channel_id:_ ~keeper_name:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "a" ])
  let unbind ~channel_id:_ ~actor_name:_ =
    Ok (`Assoc [ "variant", `String "a" ])
  let bound_channels ~keeper_name:_ = []
  let connected () = false
end

module Registry_test_connector_b = struct
  include Registry_test_connector_a

  let display_name = "Registry Test B"
  let connector_json ?gate_status_json ?(audit_limit = 10) () =
    ignore gate_status_json;
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
  let status_path = Filename.concat dir "status.json" in
  let binding_path = Filename.concat dir "bindings.json" in
  let audit_path = Filename.concat dir "audit.jsonl" in
  let names_path = Filename.concat dir "names.json" in
  with_env "MASC_DISCORD_STATUS_PATH" (Some status_path) (fun () ->
    with_env "MASC_DISCORD_BINDING_STORE_PATH" (Some binding_path) (fun () ->
      with_env "MASC_DISCORD_BINDING_AUDIT_PATH" (Some audit_path) (fun () ->
        with_env "MASC_DISCORD_NAMES_PATH" (Some names_path) f)))

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
    check bool "stale false" false
      (json |> U.member "stale" |> U.to_bool);
    check string "status source" "in_process_gateway"
      (json |> U.member "status_source" |> U.to_string);
    check string "gateway state" "disconnected"
      (json |> U.member "gateway_state" |> U.to_string);
    check string "missing-token error" "DISCORD_BOT_TOKEN is unset or empty"
      (json |> U.member "error" |> U.to_string);
    check int "no configured bindings" 0
      (json |> U.member "configured_bindings" |> U.to_list |> List.length)))

let test_status_json_ignores_legacy_sidecar_status_file () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" None (fun () ->
    let status_path = Filename.concat dir "status.json" in
    Yojson.Safe.to_file status_path
      (`Assoc
        [
          ("updated_at", `String "2026-05-10T16:49:47Z");
          ("connected", `Bool true);
          ("bot_user_name", `String "legacy-sidecar");
          ("runtime_bindings_count", `Int 99);
        ]);
    let json = Discord_state.status_json () in
    check string "source" "in_process_gateway"
      (json |> U.member "status_source" |> U.to_string);
    check bool "legacy stale file ignored" false
      (json |> U.member "stale" |> U.to_bool);
    check bool "legacy connected file ignored" false
      (json |> U.member "connected" |> U.to_bool);
    check string "legacy bot name ignored" ""
      (json |> U.member "bot_user_name" |> U.to_string);
    check int "runtime bindings from persisted bindings" 0
      (json |> U.member "runtime_bindings_count" |> U.to_int)))

(* record_ready ordering: this test runs in the same process as the
   blank-identity assertions above, so it must come after them in the
   suite — last_ready is module-global and has no reset (production
   never clears it; a fresh READY only overwrites). *)
let test_record_ready_surfaces_bot_identity () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
  with_env "DISCORD_BOT_TOKEN" None (fun () ->
    Discord_state.record_ready ~bot_user_id:"bot-42";
    let json = Discord_state.status_json () in
    check string "bot_user_id from READY" "bot-42"
      (json |> U.member "bot_user_id" |> U.to_string);
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
          (List.hd audit |> U.member "actor_name" |> U.to_string))

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

let test_connectors_json_advertises_gate_connector_descriptor () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_state.set_trigger_policy Discord_gateway_state.All;
    ignore
      (Discord_state.bind ~channel_id:"1234567890" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    let status_path = Filename.concat dir "status.json" in
    Yojson.Safe.to_file status_path
      (`Assoc
        [
          ("updated_at", `String "2026-04-09T00:00:00Z");
          ("connected", `Bool true);
          ("bot_user_name", `String "keeper-gateway");
          ("bot_user_id", `String "bot-1");
          ("guild_count", `Int 2);
          ("gate_base_url", `String "http://127.0.0.1:8935");
          ("gate_healthy", `Bool true);
          ("gate_health_checked_at", `String "2026-04-09T00:00:00Z");
          ("last_ready_at", `String "2026-04-09T00:00:00Z");
          ("binding_source", `String "persisted");
          ("runtime_bindings_count", `Int 1);
          ("pid", `Int 4242);
        ]);
    let gate_status_json =
      `Assoc
        [
          ( "channels",
            `List
              [
                `Assoc
                  [
                    ("channel", `String "discord");
                    ("message_count", `Int 3);
                    ("success_rate_pct", `Int 100);
                  ];
              ] );
        ]
    in
    Channel_gate_connector.register (module Discord_state);
    let json = Channel_gate_connector.connectors_json ~gate_status_json () in
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
    check string "observed channel surfaced" "discord"
      (connector |> U.member "observed_channel" |> U.member "channel"
       |> U.to_string))

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

let test_name_map_round_trip () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    let nm : Discord_names.name_map =
      {
        guild_names = [ ("123", "sangsu-lab") ];
        channel_names = [ ("456", "#general") ];
        channel_to_guild = [ ("456", "123") ];
        channel_to_parent = [ ("789", "456") ];
        updated_at = "2026-04-15T00:00:00Z";
      }
    in
    Discord_names.save nm;
    let loaded = Discord_names.read () in
    check string "guild name round-trips" "sangsu-lab"
      (List.assoc "123" loaded.guild_names);
    check string "channel name round-trips" "#general"
      (List.assoc "456" loaded.channel_names);
    check string "channel_to_guild round-trips" "123"
      (List.assoc "456" loaded.channel_to_guild);
    check string "channel_to_parent round-trips" "456"
      (List.assoc "789" loaded.channel_to_parent);
    check string "updated_at round-trips" "2026-04-15T00:00:00Z"
      loaded.updated_at)

let test_read_name_map_missing_returns_empty () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    let loaded = Discord_names.read () in
    check int "no guild names" 0 (List.length loaded.guild_names);
    check int "no channel names" 0 (List.length loaded.channel_names);
    check int "no channel_to_guild entries" 0
      (List.length loaded.channel_to_guild);
    check int "no channel_to_parent entries" 0
      (List.length loaded.channel_to_parent);
    check string "empty updated_at" "" loaded.updated_at)

let test_resolve_guild_id_hits_and_misses () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_names.save
      {
        guild_names = [ ("123", "sangsu-lab") ];
        channel_names = [ ("456", "#general") ];
        channel_to_guild = [ ("456", "123") ];
        channel_to_parent = [ ("789", "456") ];
        updated_at = "2026-04-15T00:00:00Z";
      };
    check (option string) "hit returns guild id" (Some "123")
      (Discord_names.resolve_guild_id_for_channel ~channel_id:"456");
    check (option string) "miss returns None" None
      (Discord_names.resolve_guild_id_for_channel ~channel_id:"999");
    check (option string) "parent hit returns parent channel id" (Some "456")
      (Discord_names.resolve_parent_channel_id_for_channel ~channel_id:"789");
    check (option string) "parent miss returns None" None
      (Discord_names.resolve_parent_channel_id_for_channel ~channel_id:"999");
    check (option string) "empty channel_id returns None" None
      (Discord_names.resolve_guild_id_for_channel ~channel_id:""))

let test_bind_populates_guild_id_when_names_available () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_names.save
      {
        guild_names = [ ("guild-1", "sangsu-lab") ];
        channel_names = [ ("chan-1", "#general") ];
        channel_to_guild = [ ("chan-1", "guild-1") ];
        channel_to_parent = [];
        updated_at = "2026-04-15T00:00:00Z";
      };
    match
      Discord_state.bind ~channel_id:"chan-1" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check string "audit guild_id resolved" "guild-1"
          (List.hd audit |> U.member "guild_id" |> U.to_string))

let test_bind_accepts_missing_names_with_empty_guild_id () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    match
      Discord_state.bind ~channel_id:"unknown" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check string "audit guild_id empty when names absent" ""
          (List.hd audit |> U.member "guild_id" |> U.to_string))

let test_resolve_keeper_for_thread_parent_binding () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_names.save
      {
        guild_names = [ ("guild-1", "sangsu-lab") ];
        channel_names = [ ("parent-1", "#personal-agents"); ("thread-1", "thread") ];
        channel_to_guild = [ ("parent-1", "guild-1"); ("thread-1", "guild-1") ];
        channel_to_parent = [ ("thread-1", "parent-1") ];
        updated_at = "2026-04-15T00:00:00Z";
      };
    ignore
      (Discord_state.bind ~channel_id:"parent-1" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    match Discord_state.resolve_keeper_for_channel ~channel_id:"thread-1" with
    | None -> fail "expected parent binding to resolve"
    | Some resolution ->
        check string "keeper" "luna" resolution.keeper_name;
        check string "incoming" "thread-1" resolution.incoming_channel_id;
        check string "bound" "parent-1" resolution.bound_channel_id;
        check bool "via parent" true resolution.via_parent)

let test_resolve_keeper_exact_binding_wins_over_parent () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    Discord_names.save
      {
        guild_names = [ ("guild-1", "sangsu-lab") ];
        channel_names = [ ("parent-1", "#personal-agents"); ("thread-1", "thread") ];
        channel_to_guild = [ ("parent-1", "guild-1"); ("thread-1", "guild-1") ];
        channel_to_parent = [ ("thread-1", "parent-1") ];
        updated_at = "2026-04-15T00:00:00Z";
      };
    ignore
      (Discord_state.bind ~channel_id:"parent-1" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    ignore
      (Discord_state.bind ~channel_id:"thread-1" ~keeper_name:"sangsu"
         ~actor_name:"dashboard");
    match Discord_state.resolve_keeper_for_channel ~channel_id:"thread-1" with
    | None -> fail "expected exact binding to resolve"
    | Some resolution ->
        check string "keeper" "sangsu" resolution.keeper_name;
        check string "incoming" "thread-1" resolution.incoming_channel_id;
        check string "bound" "thread-1" resolution.bound_channel_id;
        check bool "not via parent" false resolution.via_parent)

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

let () =
  Eio_main.run @@ fun _env ->
  run "channel_gate_discord_state"
    [
      ( "status",
        [
          test_case "in-process gateway status" `Quick
            test_status_json_reports_in_process_gateway_status;
          test_case "ignores legacy sidecar status file" `Quick
            test_status_json_ignores_legacy_sidecar_status_file;
          test_case "record_ready surfaces bot identity" `Quick
            test_record_ready_surfaces_bot_identity;
          test_case "bind persists binding and audit" `Quick
            test_bind_persists_binding_and_audit;
          test_case "unbind removes binding" `Quick
            test_unbind_removes_existing_binding;
          test_case "connectors json advertises connector descriptor" `Quick
            test_connectors_json_advertises_gate_connector_descriptor;
          test_case "registry register replaces and all snapshots" `Quick
            test_registry_register_replaces_and_all_snapshots;
        ] );
      ( "name_map",
        [
          test_case "round trip" `Quick test_name_map_round_trip;
          test_case "missing file returns empty" `Quick
            test_read_name_map_missing_returns_empty;
          test_case "resolve hits and misses" `Quick
            test_resolve_guild_id_hits_and_misses;
          test_case "bind populates guild_id when names available" `Quick
            test_bind_populates_guild_id_when_names_available;
          test_case "bind accepts missing names with empty guild_id" `Quick
            test_bind_accepts_missing_names_with_empty_guild_id;
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
    ]
