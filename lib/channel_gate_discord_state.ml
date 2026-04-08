module U = Yojson.Safe.Util

type binding = {
  channel_id : string;
  keeper_name : string;
}

type audit_event = {
  timestamp : string;
  action : string;
  guild_id : string;
  channel_id : string;
  keeper_name : string;
  actor_id : string;
  actor_name : string;
  previous_keeper : string;
}

let default_status_path = "sidecars/discord-bot/.gate/discord_status.json"
let default_binding_store_path = "sidecars/discord-bot/.gate/discord_bindings.json"
let default_binding_audit_path =
  "sidecars/discord-bot/.gate/discord_binding_audit.jsonl"

let stale_after_sec () =
  Env_config_core.get_int ~default:30 "MASC_DISCORD_STATUS_STALE_SEC"

let resolve_path raw_path =
  if Filename.is_relative raw_path then
    Filename.concat (Env_config_core.base_path ()) raw_path
  else
    raw_path

let configured_path env_name ~default =
  match Sys.getenv_opt env_name |> Env_config_core.trim_opt with
  | Some raw -> resolve_path raw
  | None -> resolve_path default

let status_path () =
  configured_path "MASC_DISCORD_STATUS_PATH" ~default:default_status_path

let binding_store_path () =
  configured_path "MASC_DISCORD_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_audit_path () =
  configured_path "MASC_DISCORD_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let read_json_file_opt path =
  if not (Sys.file_exists path) then
    None
  else
    try Some (Yojson.Safe.from_file path) with
    | Sys_error _ | Yojson.Json_error _ -> None

let normalize_bindings_json (json : Yojson.Safe.t) : binding list =
  match json with
  | `Assoc items ->
      items
      |> List.filter_map (fun (raw_channel_id, raw_keeper_name) ->
             let channel_id = String.trim raw_channel_id in
             let keeper_name =
               match raw_keeper_name with
               | `String value -> String.trim value
               | _ -> ""
             in
             if channel_id = "" || keeper_name = "" then None
             else Some ({ channel_id; keeper_name } : binding))
      |> List.sort (fun (a : binding) (b : binding) ->
             String.compare a.channel_id b.channel_id)
  | _ -> []

let read_bindings () : binding list =
  match read_json_file_opt (binding_store_path ()) with
  | Some json -> normalize_bindings_json json
  | None -> []

let binding_json (binding : binding) =
  `Assoc
    [
      ("channel_id", `String binding.channel_id);
      ("keeper_name", `String binding.keeper_name);
    ]

let save_bindings (bindings : binding list) =
  let path = binding_store_path () in
  let normalized =
    bindings
    |> List.sort (fun (a : binding) (b : binding) ->
           String.compare a.channel_id b.channel_id)
    |> List.fold_left
         (fun acc (binding : binding) ->
           (binding.channel_id, `String binding.keeper_name) :: acc)
         []
    |> List.rev
    |> fun items -> `Assoc items
  in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Yojson.Safe.pretty_to_string normalized ^ "\n"));
  Sys.rename tmp path

let audit_event_json event =
  `Assoc
    [
      ("timestamp", `String event.timestamp);
      ("action", `String event.action);
      ("guild_id", `String event.guild_id);
      ("channel_id", `String event.channel_id);
      ("keeper_name", `String event.keeper_name);
      ("actor_id", `String event.actor_id);
      ("actor_name", `String event.actor_name);
      ("previous_keeper", `String event.previous_keeper);
    ]

let append_audit_event event =
  let path = binding_audit_path () in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let oc =
    open_out_gen [ Open_creat; Open_wronly; Open_append; Open_binary ] 0o644 path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string (audit_event_json event));
      output_char oc '\n';
      flush oc;
      Unix.fsync (Unix.descr_of_out_channel oc))

let rec drop_left n xs =
  if n <= 0 then xs
  else
    match xs with
    | [] -> []
    | _ :: tl -> drop_left (n - 1) tl

let read_recent_audit ~limit =
  let path = binding_audit_path () in
  if limit <= 0 || not (Sys.file_exists path) then
    []
  else
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line -> loop (line :: acc)
          | exception End_of_file -> acc
        in
        loop []
        |> List.filter_map (fun line ->
               let trimmed = String.trim line in
               if trimmed = "" then None
               else
                 try Some (Yojson.Safe.from_string trimmed) with
                 | Yojson.Json_error _ -> None)
        |> List.rev
        |> fun rows ->
        let total = List.length rows in
        if total <= limit then List.rev rows
        else rows |> drop_left (total - limit) |> List.rev)

let string_member json key =
  json |> U.member key |> U.to_string_option |> Option.value ~default:""

let int_member json key =
  json |> U.member key |> U.to_int_option |> Option.value ~default:0

let bool_member json key =
  json |> U.member key |> U.to_bool_option |> Option.value ~default:false

let bool_option_member json key =
  json |> U.member key |> U.to_bool_option

let stale_of_updated_at updated_at =
  match Types.parse_iso8601_opt updated_at with
  | Some ts -> Unix.gettimeofday () -. ts > float_of_int (stale_after_sec ())
  | None -> true

let status_json ?(audit_limit = 10) () =
  let status_path = status_path () in
  let live_status = read_json_file_opt status_path in
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
  let error =
    if available then ""
    else "discord connector status file not found"
  in
  let status_field key f default =
    match live_status with
    | Some json -> f json key
    | None -> default
  in
  `Assoc
    [
      ("available", `Bool available);
      ("connected", `Bool connected);
      ("stale", `Bool stale);
      ("stale_after_sec", `Int (stale_after_sec ()));
      ("error", `String error);
      ("status_path", `String status_path);
      ("binding_store_path", `String (binding_store_path ()));
      ("audit_path", `String (binding_audit_path ()));
      ("updated_at", `String updated_at);
      ( "last_ready_at",
        `String (status_field "last_ready_at" string_member "") );
      ( "bot_user_name",
        `String (status_field "bot_user_name" string_member "") );
      ("bot_user_id", `String (status_field "bot_user_id" string_member ""));
      ("guild_count", `Int (status_field "guild_count" int_member 0));
      ( "gate_base_url",
        `String (status_field "gate_base_url" string_member "") );
      ( "gate_healthy",
        Option.value ~default:`Null
          (Option.map (fun value -> `Bool value)
             (match live_status with
              | Some json -> bool_option_member json "gate_healthy"
              | None -> None)) );
      ( "gate_health_checked_at",
        `String (status_field "gate_health_checked_at" string_member "") );
      ( "binding_source",
        `String (status_field "binding_source" string_member "") );
      ( "runtime_bindings_count",
        `Int (status_field "runtime_bindings_count" int_member 0) );
      ("pid", `Int (status_field "pid" int_member 0));
      ( "configured_bindings",
        `List (List.map binding_json configured_bindings) );
      ("recent_audit", `List recent_audit);
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
        {
          timestamp = Server_utils.iso8601_of_unix (Unix.gettimeofday ());
          action = "bind";
          guild_id = "";
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
            {
              timestamp = Server_utils.iso8601_of_unix (Unix.gettimeofday ());
              action = "unbind";
              guild_id = "";
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
