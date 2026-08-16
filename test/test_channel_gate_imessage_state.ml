open Alcotest

module IMessage_state = Channel_gate_imessage_state
module U = Yojson.Safe.Util

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (* On the current supported 5.4 floor there is no Unix.unsetenv; this test
     only exercises config paths that route through Env_config_core.trim_opt,
     where "" behaves like unset. *)
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
      (Printf.sprintf "imessage-state-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
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

let with_imessage_paths dir f =
  let status_path = Filename.concat dir "status.json" in
  let binding_path = Filename.concat dir "bindings.json" in
  let audit_path = Filename.concat dir "audit.jsonl" in
  with_env "MASC_IMESSAGE_STATUS_PATH" (Some status_path) (fun () ->
    with_env "MASC_IMESSAGE_BINDING_STORE_PATH" (Some binding_path) (fun () ->
      with_env "MASC_IMESSAGE_BINDING_AUDIT_PATH" (Some audit_path) f))

let sample_status_json =
  `Assoc
    [
      ("updated_at", `String "2026-04-11T00:00:00Z");
      ("connected", `Bool true);
      ("gate_base_url", `String "http://127.0.0.1:8935");
      ("gate_healthy", `Bool true);
      ("gate_health_checked_at", `String "2026-04-11T00:00:00Z");
      ("reply_mode", `String "self-chat");
      ("self_chat_guid", `String "any;-;user@example.com");
      ("last_message_at", `String "2026-04-11T00:00:00Z");
      ("messages_processed", `Int 3);
      ("messages_failed", `Int 1);
      ("cursor_rowid", `Int 42);
      ("poll_interval_sec", `Float 2.0);
      ("pid", `Int 4242);
    ]

let test_status_json_redacts_self_chat_guid () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file (Filename.concat dir "status.json") sample_status_json;
    let json = IMessage_state.status_json () in
    check string "reply mode surfaced" "self-chat"
      (json |> U.member "reply_mode" |> U.to_string);
    check string "self-chat guid redacted" "any;-;[redacted]"
      (json |> U.member "self_chat_guid" |> U.to_string))

let test_connector_json_keeps_redacted_guid () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file (Filename.concat dir "status.json") sample_status_json;
    let json = IMessage_state.connector_json () in
    check string "connector id" "imessage"
      (json |> U.member "connector_id" |> U.to_string);
    check string "reply mode surfaced" "self-chat"
      (json |> U.member "reply_mode" |> U.to_string);
    check string "self-chat guid redacted" "any;-;[redacted]"
      (json |> U.member "self_chat_guid" |> U.to_string))

(* The connector-specific fields ride on Config.extra_status_fields, so they
   are the ones that would silently disappear if the shared functor stopped
   carrying them into both views. *)
let test_cursor_rowid_surfaces_in_both_views () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file (Filename.concat dir "status.json") sample_status_json;
    check int "status json carries the cursor" 42
      (IMessage_state.status_json () |> U.member "cursor_rowid" |> U.to_int);
    check int "connector json carries the cursor" 42
      (IMessage_state.connector_json () |> U.member "cursor_rowid" |> U.to_int))

(* iMessage polls chat.db on a timer, so a status file that predates the field
   must still report the interval the sidecar actually runs at, not 0. *)
let test_poll_interval_defaults_to_the_imessage_rate () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file
      (Filename.concat dir "status.json")
      (`Assoc
        [
          ("updated_at", `String "2026-04-11T00:00:00Z"); ("connected", `Bool true);
        ]);
    check (float 0.001) "falls back to the polling rate" 2.0
      (IMessage_state.status_json () |> U.member "poll_interval_sec" |> U.to_float))

(* Only Discord has guilds. An empty guild_id on an iMessage audit entry would
   be a field that means nothing, written to the audit log on every bind. *)
let test_audit_entries_omit_guild_id () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file (Filename.concat dir "status.json") sample_status_json;
    match
      IMessage_state.bind ~channel_id:"any;-;user@example.com"
        ~keeper_name:"claude" ~actor_name:"tester"
    with
    | Error message -> failf "bind failed: %s" message
    | Ok _ ->
      let audit =
        IMessage_state.status_json () |> U.member "recent_audit" |> U.to_list
      in
      check int "one audit entry" 1 (List.length audit);
      check bool "no guild_id on the entry" true
        (List.for_all (fun entry -> U.member "guild_id" entry = `Null) audit))

(* Two OCaml readers go looking for this one file: the gate state below, and
   Server_routes_http_sidecar_paths, which the dashboard's start/stop route
   uses to decide whether the sidecar is running. They have to agree on which
   env var relocates it, or an operator who sets one moves half the readers.
   iMessage shared no name with the server until now; Telegram always did. *)
let with_binding_paths dir f =
  with_env "MASC_IMESSAGE_BINDING_STORE_PATH"
    (Some (Filename.concat dir "bindings.json"))
    (fun () ->
      with_env "MASC_IMESSAGE_BINDING_AUDIT_PATH"
        (Some (Filename.concat dir "audit.jsonl"))
        f)

let test_unprefixed_env_moves_both_readers () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    let status_path = Filename.concat dir "relocated-status.json" in
    with_env "MASC_IMESSAGE_STATUS_PATH" None (fun () ->
      with_env "IMESSAGE_STATUS_PATH" (Some status_path) (fun () ->
        Yojson.Safe.to_file status_path sample_status_json;
        check string "gate state follows IMESSAGE_STATUS_PATH" status_path
          (IMessage_state.status_json () |> U.member "status_path" |> U.to_string);
        check string "the sidecar route resolves the same file" status_path
          (Server_routes_http_sidecar_paths.status_file ~base_path:dir "imessage"))))

let test_prefixed_env_still_moves_the_gate_state () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    let status_path = Filename.concat dir "prefixed-status.json" in
    with_env "IMESSAGE_STATUS_PATH" None (fun () ->
      with_env "MASC_IMESSAGE_STATUS_PATH" (Some status_path) (fun () ->
        Yojson.Safe.to_file status_path sample_status_json;
        check string "MASC_-prefixed spelling keeps working" status_path
          (IMessage_state.status_json () |> U.member "status_path" |> U.to_string))))

let test_malformed_binding_store_is_explicit () =
  with_temp_dir @@ fun dir ->
  with_imessage_paths dir (fun () ->
    Yojson.Safe.to_file (Filename.concat dir "status.json") sample_status_json;
    let oc = open_out_bin (Filename.concat dir "bindings.json") in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    let json = IMessage_state.connector_json () in
    check bool "binding read failed" false
      (json |> U.member "binding_store_read_ok" |> U.to_bool);
    check bool "connector unavailable" false
      (json |> U.member "available" |> U.to_bool);
    check bool "binding error retained" true
      (json |> U.member "binding_store_error" |> U.to_string
       |> String.length |> ( < ) 0))

let () =
  run "channel_gate_imessage_state"
    [
      ( "status",
        [
          test_case "status json redacts self-chat guid" `Quick
            test_status_json_redacts_self_chat_guid;
          test_case "connector json keeps redacted self-chat guid" `Quick
            test_connector_json_keeps_redacted_guid;
          test_case "cursor rowid surfaces in both views" `Quick
            test_cursor_rowid_surfaces_in_both_views;
          test_case "poll interval defaults to the iMessage rate" `Quick
            test_poll_interval_defaults_to_the_imessage_rate;
          test_case "audit entries omit guild_id" `Quick
            test_audit_entries_omit_guild_id;
          test_case "unprefixed env moves both readers" `Quick
            test_unprefixed_env_moves_both_readers;
          test_case "prefixed env still moves the gate state" `Quick
            test_prefixed_env_still_moves_the_gate_state;
          test_case "malformed binding store is explicit" `Quick
            test_malformed_binding_store_is_explicit;
        ] );
    ]
