let string_member json key =
  Json_util.get_string_with_default json ~key ~default:""

let int_member json key =
  Json_util.get_int json key |> Option.value ~default:0

(* The self-chat guid is an addressable Messages.app handle, so the dashboard
   sees the routing prefix and not the address itself. *)
let redact_chat_guid raw =
  let value = String.trim raw in
  if value = "" then ""
  else
    match List.rev (String.split_on_char ';' value) with
    | _target :: rev_prefix when rev_prefix <> [] ->
        String.concat ";" (List.rev rev_prefix) ^ ";[redacted]"
    | _ -> "[redacted]"

include
  Channel_gate_sidecar_state.Make
    (struct
      let connector_id = "imessage"
      let display_name = "iMessage"
      let channel = "imessage"
      let default_status_path = ".gate/runtime/imessage/status.json"
      let default_binding_store_path = ".gate/runtime/imessage/bindings.json"

      let default_binding_audit_path =
        ".gate/runtime/imessage/binding_audit.jsonl"

      (* Both spellings, because Server_routes_http_sidecar_paths reads the
         unprefixed one when it goes looking for the same file. Telegram
         already accepts both. *)
      let status_path_env_names =
        [ "IMESSAGE_STATUS_PATH"; "MASC_IMESSAGE_STATUS_PATH" ]

      let binding_store_path_env_names =
        [ "IMESSAGE_BINDING_STORE_PATH"; "MASC_IMESSAGE_BINDING_STORE_PATH" ]

      let binding_audit_path_env_names =
        [ "IMESSAGE_BINDING_AUDIT_PATH"; "MASC_IMESSAGE_BINDING_AUDIT_PATH" ]
      let stale_after_env_name = "MASC_IMESSAGE_STATUS_STALE_SEC"

      (* iMessage has no guilds. *)
      let guild_id_field = Channel_gate_binding_store.Omit
      let default_poll_interval_sec = 2.0

      let extra_status_fields live_status =
        let string_field key =
          match live_status with Some json -> string_member json key | None -> ""
        in
        let int_field key =
          match live_status with Some json -> int_member json key | None -> 0
        in
        [
          ("reply_mode", `String (string_field "reply_mode"));
          ( "self_chat_guid",
            `String (redact_chat_guid (string_field "self_chat_guid")) );
          ("cursor_rowid", `Int (int_field "cursor_rowid"));
        ]
    end)
