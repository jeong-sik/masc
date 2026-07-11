module U = Yojson.Safe.Util
module Store = Channel_gate_binding_store

type binding = Store.binding = {
  channel_id : string;
  keeper_name : string;
}

let connector_id = "imessage"
let display_name = "iMessage"
let channel = "imessage"

let default_status_path = ".gate/runtime/imessage/status.json"
let default_binding_store_path = ".gate/runtime/imessage/bindings.json"
let default_binding_audit_path = ".gate/runtime/imessage/binding_audit.jsonl"

let stale_after_sec () =
  Env_config_core.get_int ~default:30 "MASC_IMESSAGE_STATUS_STALE_SEC"

let resolve_path raw_path =
  if Filename.is_relative raw_path then
    Filename.concat (Env_config_core.base_path ()) raw_path
  else
    raw_path

let redact_chat_guid raw =
  let value = String.trim raw in
  if value = "" then ""
  else
    match List.rev (String.split_on_char ';' value) with
    | _target :: rev_prefix when rev_prefix <> [] ->
        String.concat ";" (List.rev rev_prefix) ^ ";[redacted]"
    | _ -> "[redacted]"

let configured_write_path env_name ~default =
  match Sys.getenv_opt env_name |> Env_config_core.trim_opt with
  | Some raw -> resolve_path raw
  | None -> resolve_path default

let status_path () =
  configured_write_path "MASC_IMESSAGE_STATUS_PATH" ~default:default_status_path

let status_write_path () =
  configured_write_path "MASC_IMESSAGE_STATUS_PATH" ~default:default_status_path

let binding_store_path () =
  configured_write_path "MASC_IMESSAGE_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_store_read_path () =
  configured_write_path "MASC_IMESSAGE_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_audit_path () =
  configured_write_path "MASC_IMESSAGE_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let binding_audit_read_path () =
  configured_write_path "MASC_IMESSAGE_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let binding_store =
  Store.create ~binding_store_path ~binding_store_read_path ~binding_audit_path
    ~binding_audit_read_path ~guild_id_field:Store.Omit

let read_json_file_opt = Store.read_json_file_opt
let read_bindings () = Store.read_bindings binding_store
let binding_json = Store.binding_json
let save_bindings bindings = Store.save_bindings binding_store bindings
let append_audit_event event = Store.append_audit_event binding_store event
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

let string_member json key =
  Json_util.get_string_with_default json ~key ~default:""

let int_member json key =
  Json_util.get_int json key |> Option.value ~default:0

let bool_member json key =
  Json_util.get_bool json key |> Option.value ~default:false

let bool_option_member json key =
  Json_util.get_bool json key

let stale_of_updated_at updated_at =
  match Gate_time_util.parse_iso8601_opt updated_at with
  | Some ts -> Unix.gettimeofday () -. ts > float_of_int (stale_after_sec ())
  | None -> true

let connector_state_label ~available ~connected ~stale =
  if not available then "offline"
  else if stale then "stale"
  else if connected then "connected"
  else "disconnected"

(* RFC-0223 P2: presence surface. Both recomputed per call — no cached
   presence state. *)

let bound_channels ~keeper_name =
  let normalized = String.trim keeper_name in
  if String.equal normalized "" then []
  else
    read_bindings ()
    |> List.filter_map (fun (b : binding) ->
           if String.equal b.keeper_name normalized then Some b.channel_id
           else None)

let connected () =
  (* Same liveness reading as [status_json]: the sidecar heartbeats its
     status file; a missing or stale file means not live. *)
  match read_json_file_opt (status_path ()) with
  | None -> false
  | Some json ->
      let updated_at = string_member json "updated_at" in
      bool_member json "connected" && not (stale_of_updated_at updated_at)

let status_json ?(audit_limit = 10) () =
  let status_path = status_path () in
  let live_status = read_json_file_opt status_path in
  let binding_store_path = binding_store_read_path () in
  let audit_path = binding_audit_read_path () in
  let configured_bindings = read_bindings () in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  let available = Option.is_some live_status in
  let updated_at =
    match live_status with
    | Some json -> string_member json "updated_at"
    | None -> ""
  in
  let stale = if not available then true else stale_of_updated_at updated_at in
  let connected =
    match live_status with
    | Some json -> bool_member json "connected" && not stale
    | None -> false
  in
  let error = if available then "" else "connector status file not found" in
  let status_field key f default =
    match live_status with
    | Some json -> f json key
    | None -> default
  in
  `Assoc
    [
      ("channel", `String channel);
      ("available", `Bool available);
      ("connected", `Bool connected);
      ("stale", `Bool stale);
      ("stale_after_sec", `Int (stale_after_sec ()));
      ("status", `String (connector_state_label ~available ~connected ~stale));
      ("error", `String error);
      ("status_path", `String status_path);
      ("binding_store_path", `String binding_store_path);
      ("audit_path", `String audit_path);
      ("updated_at", `String updated_at);
      ("reply_mode", `String (status_field "reply_mode" string_member ""));
      ( "self_chat_guid",
        `String
          (redact_chat_guid (status_field "self_chat_guid" string_member "")) );
      ("last_message_at", `String (status_field "last_message_at" string_member ""));
      ("messages_processed", `Int (status_field "messages_processed" int_member 0));
      ("messages_failed", `Int (status_field "messages_failed" int_member 0));
      ("cursor_rowid", `Int (status_field "cursor_rowid" int_member 0));
      ("poll_interval_sec", `Float (status_field "poll_interval_sec" (fun j k -> Json_util.get_float j k |> Option.value ~default:2.0) 2.0));
      ("gate_base_url", `String (status_field "gate_base_url" string_member ""));
      ( "gate_healthy",
        Option.value ~default:`Null
          (Option.map (fun value -> `Bool value)
             (match live_status with
              | Some json -> bool_option_member json "gate_healthy"
              | None -> None)) );
      ( "gate_health_checked_at",
        `String (status_field "gate_health_checked_at" string_member "") );
      ("pid", `Int (status_field "pid" int_member 0));
      ("configured_bindings", `List (List.map binding_json configured_bindings));
      ("recent_audit", `List recent_audit);
    ]

let list_assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let find_assoc_by_string_field ~field ~value = function
  | `List rows ->
      List.find_map
        (function
          | (`Assoc _ as row) -> (
              match list_assoc_field field row with
              | Some (`String candidate) when String.equal candidate value ->
                  Some row
              | _ -> None)
          | _ -> None)
        rows
  | _ -> None

let connector_json ?gate_status_json ?(audit_limit = 10) () =
  let status = status_json ~audit_limit () in
  let observed_channel =
    match gate_status_json with
    | None -> `Null
    | Some json -> (
        match list_assoc_field "channels" json with
        | Some channels -> (
            match
              find_assoc_by_string_field ~field:"channel" ~value:channel channels
            with
            | Some row -> row
            | None -> `Null)
        | None -> `Null)
  in
  `Assoc
    [
      ("connector_id", `String connector_id);
      ("display_name", `String display_name);
      ("channel", `String channel);
      ("capabilities", Channel_gate_connector_capability.all_json);
      ("status", `String (string_member status "status"));
      ("available", `Bool (bool_member status "available"));
      ("connected", `Bool (bool_member status "connected"));
      ("stale", `Bool (bool_member status "stale"));
      ("stale_after_sec", `Int (int_member status "stale_after_sec"));
      ("error", `String (string_member status "error"));
      ("updated_at", `String (string_member status "updated_at"));
      ("reply_mode", `String (string_member status "reply_mode"));
      ("self_chat_guid", `String (string_member status "self_chat_guid"));
      ("last_message_at", `String (string_member status "last_message_at"));
      ("messages_processed", `Int (int_member status "messages_processed"));
      ("messages_failed", `Int (int_member status "messages_failed"));
      ("cursor_rowid", `Int (int_member status "cursor_rowid"));
      ("poll_interval_sec", status |> U.member "poll_interval_sec");
      ("gate_base_url", `String (string_member status "gate_base_url"));
      ( "gate_healthy",
        Option.value ~default:`Null
          (Option.map (fun value -> `Bool value)
             (bool_option_member status "gate_healthy")) );
      ( "gate_health_checked_at",
        `String (string_member status "gate_health_checked_at") );
      ("pid", `Int (int_member status "pid"));
      ("configured_bindings", status |> U.member "configured_bindings");
      ("recent_audit", status |> U.member "recent_audit");
      ("observed_channel", observed_channel);
    ]

let rollback_bindings original_bindings =
  try save_bindings original_bindings with
  | Sys_error _ -> ()

let bind ~channel_id ~keeper_name ~actor_name =
  let channel_id = String.trim channel_id in
  let keeper_name = String.trim keeper_name in
  if channel_id = "" then
    Error "channel_id is required"
  else if keeper_name = "" then
    Error "keeper_name is required"
  else
    let original_bindings = read_bindings () in
    let previous_keeper =
      original_bindings
      |> List.find_map (fun (binding : binding) ->
             if String.equal binding.channel_id channel_id then
               Some binding.keeper_name
             else
               None)
      |> Option.value ~default:""
    in
    let updated_bindings =
      (({ channel_id; keeper_name } : binding)
       :: List.filter
            (fun (binding : binding) ->
              not (String.equal binding.channel_id channel_id))
            original_bindings)
      |> List.sort (fun (a : binding) (b : binding) ->
             String.compare a.channel_id b.channel_id)
    in
    try
      save_bindings updated_bindings;
      append_audit_event
        Store.{
          timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
          action = "bind";
          guild_id = None;
          channel_id;
          keeper_name;
          actor_id = actor_name;
          actor_name;
          previous_keeper;
        };
      Ok (status_json ())
    with
    | Sys_error msg ->
        rollback_bindings original_bindings;
        Error msg

let unbind ~channel_id ~actor_name =
  let channel_id = String.trim channel_id in
  if channel_id = "" then
    Error "channel_id is required"
  else
    let original_bindings = read_bindings () in
    match
      original_bindings
      |> List.find_opt (fun (binding : binding) ->
             String.equal binding.channel_id channel_id)
    with
    | None -> Error "binding not found"
    | Some (removed_binding : binding) ->
        let updated_bindings =
          List.filter
            (fun (binding : binding) ->
              not (String.equal binding.channel_id channel_id))
            original_bindings
        in
        try
          save_bindings updated_bindings;
          append_audit_event
            Store.{
              timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
              action = "unbind";
              guild_id = None;
              channel_id;
              keeper_name = removed_binding.keeper_name;
              actor_id = actor_name;
              actor_name;
              previous_keeper = removed_binding.keeper_name;
            };
          Ok (status_json ())
        with
        | Sys_error msg ->
            rollback_bindings original_bindings;
            Error msg
