open Alcotest

module Discord_state = Masc_mcp.Channel_gate_discord_state
module U = Yojson.Safe.Util

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

let with_temp_dir f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "discord-state-%06x" (Random.bits ()))
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
  with_env "MASC_DISCORD_STATUS_PATH" (Some status_path) (fun () ->
    with_env "MASC_DISCORD_BINDING_STORE_PATH" (Some binding_path) (fun () ->
      with_env "MASC_DISCORD_BINDING_AUDIT_PATH" (Some audit_path) f))

let test_status_json_reports_missing_live_status () =
  with_temp_dir @@ fun dir ->
  with_discord_paths dir (fun () ->
    let json = Discord_state.status_json () in
    check bool "available false" false
      (json |> U.member "available" |> U.to_bool);
    check bool "connected false" false
      (json |> U.member "connected" |> U.to_bool);
    check bool "stale true" true
      (json |> U.member "stale" |> U.to_bool);
    check int "no configured bindings" 0
      (json |> U.member "configured_bindings" |> U.to_list |> List.length))

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
    let json = Discord_state.connectors_json ~gate_status_json () in
    let connectors = json |> U.member "connectors" |> U.to_list in
    check int "one connector" 1 (List.length connectors);
    let connector = List.hd connectors in
    check string "connector id" "discord"
      (connector |> U.member "connector_id" |> U.to_string);
    check string "display name" "Discord"
      (connector |> U.member "display_name" |> U.to_string);
    check bool "bindings capability exposed" true
      (connector |> U.member "capabilities" |> U.to_list
       |> List.exists (function
            | `String "bindings" -> true
            | _ -> false));
    check string "observed channel surfaced" "discord"
      (connector |> U.member "observed_channel" |> U.member "channel"
       |> U.to_string))

let () =
  Random.self_init ();
  run "channel_gate_discord_state"
    [
      ( "status",
        [
          test_case "missing live status" `Quick
            test_status_json_reports_missing_live_status;
          test_case "bind persists binding and audit" `Quick
            test_bind_persists_binding_and_audit;
          test_case "unbind removes binding" `Quick
            test_unbind_removes_existing_binding;
          test_case "connectors json advertises connector descriptor" `Quick
            test_connectors_json_advertises_gate_connector_descriptor;
        ] );
    ]
