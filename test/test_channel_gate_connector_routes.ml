open Alcotest

module Routes = Server_routes_http_routes_channel_gate
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

let rec with_envs names value f =
  match names with
  | [] -> f ()
  | name :: rest -> with_env name value (fun () -> with_envs rest value f)

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "sidecar-state-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
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

let with_sidecar_paths prefix dir f =
  let status_path = Filename.concat dir (prefix ^ "-status.json") in
  let binding_path = Filename.concat dir (prefix ^ "-bindings.json") in
  let audit_path = Filename.concat dir (prefix ^ "-audit.jsonl") in
  let env_names suffix =
    let legacy = String.uppercase_ascii prefix ^ suffix in
    [ legacy; "MASC_" ^ legacy ]
  in
  with_envs (env_names "_STATUS_PATH") (Some status_path) (fun () ->
    with_envs (env_names "_BINDING_STORE_PATH") (Some binding_path) (fun () ->
      with_envs (env_names "_BINDING_AUDIT_PATH") (Some audit_path) f))

let test_resolve_connector_status_name_prefers_explicit_name () =
  check (option string) "name wins and normalizes" (Some "discord")
    (Routes.resolve_connector_status_name ~name:"  Discord  "
       ~channel:"telegram" ())

let test_resolve_connector_status_name_normalizes_legacy_channel () =
  check (option string) "legacy channel lowercased" (Some "discord")
    (Routes.resolve_connector_status_name ~channel:"  DISCORD  " ())

let test_resolve_connector_status_name_ignores_blank_inputs () =
  check (option string) "blank query params ignored" None
    (Routes.resolve_connector_status_name ~name:"   " ~channel:"   " ())

let python_utc_iso_now () =
  let z = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  String.sub z 0 (String.length z - 1) ^ ".123456+00:00"

let test_gate_time_parser_accepts_python_utc_isoformat () =
  check bool "python UTC isoformat parsed" true
    (Option.is_some (Gate_time_util.parse_iso8601_opt (python_utc_iso_now ())));
  check bool "non-UTC offset remains rejected" true
    (Option.is_none
       (Gate_time_util.parse_iso8601_opt "2026-06-06T00:00:00+09:00"))

let test_slack_bind_persists_binding_and_audit () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    match
      Channel_gate_slack_state.bind ~channel_id:"C123" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        check string "channel" "slack" (json |> U.member "channel" |> U.to_string);
        let bindings = json |> U.member "configured_bindings" |> U.to_list in
        check int "one configured binding" 1 (List.length bindings);
        check int "runtime binding count" 1
          (json |> U.member "runtime_bindings_count" |> U.to_int);
        check string "keeper persisted" "luna"
          (List.hd bindings |> U.member "keeper_name" |> U.to_string);
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check int "one audit event" 1 (List.length audit);
        check string "audit actor" "dashboard"
          (List.hd audit |> U.member "actor_name" |> U.to_string))

let test_slack_binding_store_error_is_typed () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    let binding_path = Filename.concat dir "slack-bindings.json" in
    let oc = open_out_bin binding_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    match
      Channel_gate_slack_state.resolve_keeper_for_channel_result
        ~channel_id:"C123"
    with
    | Ok _ -> fail "expected invalid Slack binding store to return Error"
    | Error err -> check bool "reports read error" true (String.length err > 0))


let test_slack_default_paths_resolve_under_base_path () =
  with_temp_dir @@ fun base_dir ->
  with_temp_dir @@ fun cwd_dir ->
  with_env "MASC_BASE_PATH" (Some base_dir) (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_envs
        [ "SLACK_STATUS_PATH"; "MASC_SLACK_STATUS_PATH"; "SLACK_BINDING_STORE_PATH"
        ; "MASC_SLACK_BINDING_STORE_PATH"; "SLACK_BINDING_AUDIT_PATH"
        ; "MASC_SLACK_BINDING_AUDIT_PATH" ]
        None
        (fun () ->
          let original_cwd = Sys.getcwd () in
          Fun.protect
            ~finally:(fun () -> Sys.chdir original_cwd)
            (fun () ->
              Sys.chdir cwd_dir;
              match
                Channel_gate_slack_state.bind ~channel_id:"C123"
                  ~keeper_name:"luna" ~actor_name:"dashboard"
              with
              | Error err -> fail err
              | Ok json ->
                let expected_binding_path =
                  Filename.concat base_dir ".gate/runtime/slack/bindings.json"
                in
                check string "binding store path under base" expected_binding_path
                  (json |> U.member "binding_store_path" |> U.to_string);
                check bool "binding written under base" true
                  (Sys.file_exists expected_binding_path);
                check bool "binding not written under cwd" false
                  (Sys.file_exists
                     (Filename.concat cwd_dir
                        ".gate/runtime/slack/bindings.json")))))))

let test_telegram_connector_json_reads_runtime_status () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "telegram" dir (fun () ->
    ignore
      (Channel_gate_telegram_state.bind ~channel_id:"12345" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    let status_path = Filename.concat dir "telegram-status.json" in
    Yojson.Safe.to_file status_path
      (`Assoc
        [
          ("updated_at", `String (python_utc_iso_now ()));
          ("connected", `Bool true);
          ("gate_base_url", `String "http://127.0.0.1:8935");
          ("gate_healthy", `Bool true);
          ("gate_health_checked_at", `String (python_utc_iso_now ()));
          ("last_message_at", `String "2026-06-06T00:00:00Z");
          ("messages_processed", `Int 7);
          ("messages_failed", `Int 1);
          ("binding_source", `String "persisted");
          ("runtime_bindings_count", `Int 1);
          ("pid", `Int 4242);
        ]);
    let json = Channel_gate_telegram_state.connector_json () in
    check string "connector id" "telegram"
      (json |> U.member "connector_id" |> U.to_string);
    check bool "available" true (json |> U.member "available" |> U.to_bool);
    check bool "connected" true (json |> U.member "connected" |> U.to_bool);
    check int "messages processed" 7
      (json |> U.member "messages_processed" |> U.to_int);
    check int "configured bindings count" 1
      (json |> U.member "configured_bindings" |> U.to_list |> List.length))

let () =
  run "channel_gate_connector_routes"
    [
      ( "resolve_connector_status_name",
        [
          test_case "prefers explicit name" `Quick
            test_resolve_connector_status_name_prefers_explicit_name;
          test_case "normalizes legacy channel" `Quick
            test_resolve_connector_status_name_normalizes_legacy_channel;
          test_case "ignores blank inputs" `Quick
            test_resolve_connector_status_name_ignores_blank_inputs;
        ] );
      ( "sidecar_connector_state",
        [
          test_case "gate time parses python UTC isoformat" `Quick
            test_gate_time_parser_accepts_python_utc_isoformat;
          test_case "slack bind persists binding and audit" `Quick
            test_slack_bind_persists_binding_and_audit;
          test_case "slack binding read errors are typed" `Quick
            test_slack_binding_store_error_is_typed;
          test_case "slack default paths resolve under base path" `Quick
            test_slack_default_paths_resolve_under_base_path;
          test_case "telegram connector json reads runtime status" `Quick
            test_telegram_connector_json_reads_runtime_status;
        ] );
    ]
