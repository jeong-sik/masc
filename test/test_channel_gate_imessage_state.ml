open Alcotest

module IMessage_state = Channel_gate_imessage_state
module U = Yojson.Safe.Util

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (* OCaml stdlib lacks Unix.unsetenv; this test only exercises config paths
     that route through Env_config_core.trim_opt, where "" behaves like unset. *)
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

let () =
  run "channel_gate_imessage_state"
    [
      ( "status",
        [
          test_case "status json redacts self-chat guid" `Quick
            test_status_json_redacts_self_chat_guid;
          test_case "connector json keeps redacted self-chat guid" `Quick
            test_connector_json_keeps_redacted_guid;
        ] );
    ]
