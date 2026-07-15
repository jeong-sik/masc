module U = Yojson.Safe.Util
module Store = Channel_gate_binding_store

type binding = Store.binding = {
  channel_id : string;
  keeper_name : string;
}

module Names = Channel_gate_discord_names

let connector_id = "discord"
let display_name = "Discord"
let channel = "discord"


let default_status_path = ".gate/runtime/discord/status.json"
let default_binding_store_path = ".gate/runtime/discord/bindings.json"
let default_binding_audit_path = ".gate/runtime/discord/binding_audit.jsonl"

let stale_after_sec () =
  Env_config_core.get_int ~default:30 "MASC_DISCORD_STATUS_STALE_SEC"

let status_path () =
  Names.configured_write_path "MASC_DISCORD_STATUS_PATH"
    ~default:default_status_path

let status_write_path () =
  Names.configured_write_path "MASC_DISCORD_STATUS_PATH"
    ~default:default_status_path

let binding_store_path () =
  Names.configured_write_path "MASC_DISCORD_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_store_read_path () =
  Names.configured_write_path "MASC_DISCORD_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_audit_path () =
  Names.configured_write_path "MASC_DISCORD_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let binding_audit_read_path () =
  Names.configured_write_path "MASC_DISCORD_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let binding_store =
  Store.create ~binding_store_path ~binding_store_read_path ~binding_audit_path
    ~binding_audit_read_path ~guild_id_field:Store.Include_event_value

let read_bindings () = Store.read_bindings binding_store
let read_bindings_result () = Store.read_bindings_result binding_store
let binding_json = Store.binding_json
let save_bindings bindings = Store.save_bindings binding_store bindings
let append_audit_event event = Store.append_audit_event binding_store event
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

(* ── Thread registry ──────────────────────────────────────────────
   Thread→parent mapping populated from THREAD_CREATE gateway events.
   Used by [resolve_keeper_for_channel_result] to resolve bindings for thread
   messages whose channel_id is the thread's snowflake, not the parent
   channel's. Module-level mutable state (same pattern as [last_ready]). *)

let thread_parent_table : (string, string) Hashtbl.t =
  Hashtbl.create 16

let thread_parent_table_mu = Eio.Mutex.create ()

let register_thread ~thread_id ~parent_channel_id =
  let tid = String.trim thread_id in
  let pid = String.trim parent_channel_id in
  if tid <> "" && pid <> "" then
    Eio.Mutex.use_rw ~protect:true thread_parent_table_mu
    @@ fun () -> Hashtbl.replace thread_parent_table tid pid

let parent_channel_of_thread ~channel_id : string option =
  let cid = String.trim channel_id in
  if cid = "" then None
  else Eio.Mutex.use_ro thread_parent_table_mu
    @@ fun () -> Hashtbl.find_opt thread_parent_table cid

let is_known_thread ~channel_id =
  let cid = String.trim channel_id in
  cid <> ""
  && Eio.Mutex.use_ro thread_parent_table_mu
    @@ fun () -> Hashtbl.mem thread_parent_table cid

let registered_thread_count () =
  Eio.Mutex.use_ro thread_parent_table_mu
  @@ fun () -> Hashtbl.length thread_parent_table

let unregister_thread ~thread_id =
  let tid = String.trim thread_id in
  if tid <> "" then
    Eio.Mutex.use_rw ~protect:true thread_parent_table_mu
    @@ fun () -> Hashtbl.remove thread_parent_table tid

(* ── Trigger policy registry ──────────────────────────────────────
   Set once at gateway startup by [set_trigger_policy]. Read by
   this connector's status projection for dashboard display. Same
   mutable-ref pattern as [record_ready]. *)

let trigger_policy_ref : Discord_gateway_state.trigger_policy option ref =
  ref None

let set_trigger_policy (policy : Discord_gateway_state.trigger_policy) =
  trigger_policy_ref := Some policy

let get_trigger_policy () = !trigger_policy_ref

let trigger_policy_json () =
  match get_trigger_policy () with
  | None -> `Null
  | Some policy ->
    `String (Discord_gateway_state.trigger_policy_to_string policy)

let string_member json key =
  Json_util.get_string_with_default json ~key ~default:""

let int_member json key =
  Json_util.get_int json key |> Option.value ~default:0

let bool_member json key =
  Json_util.get_bool json key |> Option.value ~default:false

let bool_option_member json key =
  Json_util.get_bool json key

let connector_state_label ~available ~connected ~stale =
  if not available then "offline"
  else if stale then "stale"
  else if connected then "connected"
  else "disconnected"

let bot_token_opt () =
  match Sys.getenv_opt "DISCORD_BOT_TOKEN" with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed

let gateway_state_label = function
  | Discord_gateway_state.Disconnected -> "disconnected"
  | Awaiting_hello -> "awaiting_hello"
  | Identifying -> "identifying"
  | Resuming -> "resuming"
  | Connected _ -> "connected"
  | Reconnect_pending _ -> "reconnect_pending"
  | Failed _ -> "failed"

(* Bot identity captured from the gateway's READY dispatch. The legacy
   sidecar wrote this to status.json; the in-process gateway (RFC-0203)
   keeps it in memory — nothing writes that file anymore. *)
type ready_info = {
  ready_bot_user_id : string;
  ready_at : string;
}

let last_ready : ready_info option Atomic.t = Atomic.make None

let record_ready ~bot_user_id =
  Atomic.set last_ready
    (Some
       {
         ready_bot_user_id = bot_user_id;
         (* NDT-OK: READY wall-clock is operator-facing telemetry only
            (status_json last_ready_at); no control flow reads it. *)
         ready_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
       })

let status_json ?(audit_limit = 10) () =
  let status_path = status_path () in
  let binding_store_path = binding_store_read_path () in
  let audit_path = binding_audit_read_path () in
  let names_path = Names.names_read_path () in
  let name_map = Names.read () in
  let configured_bindings = read_bindings () in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  let channel = "discord" in
  let gateway_state = Discord_gateway_client.connection_state () in
  let token_present = Option.is_some (bot_token_opt ()) in
  let available =
    match gateway_state with
    | Disconnected -> token_present
    | Awaiting_hello | Identifying | Resuming | Connected _
    | Reconnect_pending _ | Failed _ -> true
  in
  let connected =
    match gateway_state with
    | Connected _ -> true
    | Disconnected | Awaiting_hello | Identifying | Resuming
    | Reconnect_pending _ | Failed _ -> false
  in
  let stale = false in
  (* NDT-OK: status_json is a dashboard observation boundary; this timestamp
     only reports gateway freshness and is not used for control flow. *)
  let updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  let error =
    match gateway_state with
    | Disconnected ->
      if token_present then "" else "DISCORD_BOT_TOKEN is unset or empty"
    | Failed msg -> msg
    | Awaiting_hello | Identifying | Resuming | Connected _
    | Reconnect_pending _ -> ""
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
      ("status_source", `String "in_process_gateway");
      ("gateway_state", `String (gateway_state_label gateway_state));
      ("trigger_policy", trigger_policy_json ());
      ("status_path", `String status_path);
      ("binding_store_path", `String binding_store_path);
      ("audit_path", `String audit_path);
      ("names_path", `String names_path);
      ("names", Names.to_json name_map);
      ("updated_at", `String updated_at);
      ( "last_ready_at",
        (* The READY timestamp survives reconnect_pending/resuming dips,
           so operators can tell "was up, recovering" from "never came
           up" — current liveness is gateway_state above. *)
        `String
          (match Atomic.get last_ready with
           | Some { ready_at; _ } -> ready_at
           | None -> "") );
      (* READY carries only the bot user id; the gateway does not parse
         the username. Empty is honest — the dead sidecar file used to
         supply a stale value here. *)
      ("bot_user_name", `String "");
      ( "bot_user_id",
        `String
          (match Atomic.get last_ready with
           | Some { ready_bot_user_id; _ } -> ready_bot_user_id
           | None -> "") );
      ("guild_count", `Int 0);
      ("gate_base_url", `String "in-process");
      ("gate_healthy", if connected then `Bool true else `Null);
      ("gate_health_checked_at", `String (if connected then updated_at else ""));
      ("binding_source", `String "persisted");
      ("runtime_bindings_count", `Int (List.length configured_bindings));
      (* NDT-OK: pid is process identity telemetry for operators; availability
         and connection status come from the gateway state above. *)
      ("pid", `Int (if available then Unix.getpid () else 0));
      ( "configured_bindings",
        `List (List.map binding_json configured_bindings) );
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
              find_assoc_by_string_field ~field:"channel" ~value:channel
                channels
            with
            | Some row -> row
            | None -> `Null)
        | None -> `Null)
  in
  let storage_paths =
    `Assoc
      [
        ("status_path", `String (string_member status "status_path"));
        ( "binding_store_path",
          `String (string_member status "binding_store_path") );
        ("audit_path", `String (string_member status "audit_path"));
        ("names_path", `String (string_member status "names_path"));
      ]
  in
  let runtime_summary =
    `Assoc
      [
        ("available", `Bool (bool_member status "available"));
        ("connected", `Bool (bool_member status "connected"));
        ("stale", `Bool (bool_member status "stale"));
        ("stale_after_sec", `Int (int_member status "stale_after_sec"));
        ("status", `String (string_member status "status"));
        ("error", `String (string_member status "error"));
        ("updated_at", `String (string_member status "updated_at"));
        ("last_ready_at", `String (string_member status "last_ready_at"));
        ("bot_user_name", `String (string_member status "bot_user_name"));
        ("bot_user_id", `String (string_member status "bot_user_id"));
        ("guild_count", `Int (int_member status "guild_count"));
        ("gate_base_url", `String (string_member status "gate_base_url"));
        ( "gate_healthy",
          Option.value ~default:`Null
            (Option.map (fun value -> `Bool value)
               (bool_option_member status "gate_healthy")) );
        ( "gate_health_checked_at",
          `String (string_member status "gate_health_checked_at") );
        ("pid", `Int (int_member status "pid"));
      ]
  in
  let binding_summary =
    `Assoc
      [
        ("binding_source", `String (string_member status "binding_source"));
        ( "runtime_bindings_count",
          `Int (int_member status "runtime_bindings_count") );
        ( "configured_bindings_count",
          `Int
            (Json_util.get_array status "configured_bindings"
             |> Option.map (function `List l -> List.length l | _ -> 0)
             |> Option.value ~default:0)
        );
      ]
  in
  `Assoc
    [
      ("connector_id", `String connector_id);
      ("display_name", `String display_name);
      ("channel", `String channel);
      ("capabilities", Channel_gate_connector_capability.all_json);
      ("trigger_policy", status |> U.member "trigger_policy");
      ("status", `String (string_member status "status"));
      ("available", `Bool (bool_member status "available"));
      ("connected", `Bool (bool_member status "connected"));
      ("stale", `Bool (bool_member status "stale"));
      ("stale_after_sec", `Int (int_member status "stale_after_sec"));
      ("error", `String (string_member status "error"));
      ("status_path", `String (string_member status "status_path"));
      ("binding_store_path", `String (string_member status "binding_store_path"));
      ("audit_path", `String (string_member status "audit_path"));
      ("names_path", `String (string_member status "names_path"));
      ("names", status |> U.member "names");
      ("updated_at", `String (string_member status "updated_at"));
      ("last_ready_at", `String (string_member status "last_ready_at"));
      ("bot_user_name", `String (string_member status "bot_user_name"));
      ("bot_user_id", `String (string_member status "bot_user_id"));
      ("guild_count", `Int (int_member status "guild_count"));
      ("gate_base_url", `String (string_member status "gate_base_url"));
      ( "gate_healthy",
        Option.value ~default:`Null
          (Option.map (fun value -> `Bool value)
             (bool_option_member status "gate_healthy")) );
      ( "gate_health_checked_at",
        `String (string_member status "gate_health_checked_at") );
      ("binding_source", `String (string_member status "binding_source"));
      ("runtime_bindings_count", `Int (int_member status "runtime_bindings_count"));
      ("pid", `Int (int_member status "pid"));
      ("configured_bindings", status |> U.member "configured_bindings");
      ("recent_audit", status |> U.member "recent_audit");
      ("storage_paths", storage_paths);
      ("runtime_summary", runtime_summary);
      ("binding_summary", binding_summary);
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
      let guild_id =
        Option.value (Names.resolve_guild_id_for_channel ~channel_id) ~default:""
      in
      append_audit_event
        Store.{
          timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
          action = "bind";
          guild_id = Some guild_id;
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
          let guild_id =
            Option.value (Names.resolve_guild_id_for_channel ~channel_id) ~default:""
          in
          append_audit_event
            Store.{
              timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
              action = "unbind";
              guild_id = Some guild_id;
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

(* ---------------------------------------------------------------- *)
(* In-process gateway support — replaces sidecars/discord-bot/      *)
(* ---------------------------------------------------------------- *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

type binding_lookup_error =
  | Binding_store_read_failed of string

let pp_binding_lookup_error formatter = function
  | Binding_store_read_failed detail ->
      Format.fprintf formatter "Discord binding store read failed: %s" detail

let binding_for_channel bindings ~channel_id =
  List.find_map
    (fun (b : binding) ->
      if String.equal b.channel_id channel_id then Some b else None)
    bindings

let resolve_keeper_for_channel_result ~channel_id =
  let normalized = String.trim channel_id in
  if String.equal normalized "" then Ok None
  else
    match read_bindings_result () with
    | Error detail -> Error (Binding_store_read_failed detail)
    | Ok candidates ->
      let binding, via_parent =
        match binding_for_channel candidates ~channel_id:normalized with
        | Some binding -> Some binding, false
        | None ->
          let parent_binding =
            Option.bind
              (parent_channel_of_thread ~channel_id:normalized)
              (fun parent_channel_id ->
              if String.equal parent_channel_id normalized
              then None
              else binding_for_channel candidates ~channel_id:parent_channel_id)
          in
          parent_binding, true
      in
      Ok
        (Option.map
           (fun (binding : binding) ->
             { keeper_name = binding.keeper_name
             ; incoming_channel_id = normalized
             ; bound_channel_id = binding.channel_id
             ; via_parent
             })
           binding)

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
  (* The in-process gateway (RFC-0203) is the only Discord transport;
     its run loop publishes the typed connection state. The legacy
     sidecar status file is not consulted: nothing writes it since the
     Python sidecar was deleted. *)
  match Discord_gateway_client.connection_state () with
  | Discord_gateway_state.Connected _ -> true
  | Disconnected | Awaiting_hello | Identifying | Resuming
  | Reconnect_pending _ | Failed _ ->
      false

type send_error =
  | Missing_token
  | Rest_error of Discord_rest_client.error

let pp_send_error fmt = function
  | Missing_token ->
    Format.fprintf fmt "DISCORD_BOT_TOKEN is unset or empty"
  | Rest_error e ->
    Format.fprintf fmt "discord rest error: %a" Discord_rest_client.pp_error e

let send_message ~channel_id ~content ?reply_to_message_id () =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
    let limit = Discord_rest_client.message_content_limit in
    let len = String.length content in
    if len <= limit then
      (match Discord_rest_client.send_message ~token ~channel_id ~content ?reply_to_message_id () with
       | Ok id -> Ok id
       | Error e -> Error (Rest_error e))
    else
      let rec send_chunks first rest =
        (* Split on a codepoint boundary: the Discord limit is in Unicode
           scalar values, and a mid-codepoint byte cut yields invalid
           UTF-8 that Discord rejects with a 400. *)
        let chunk, remaining_str =
          Discord_rest_client.split_at_codepoint rest ~limit
        in
        let remaining =
          if remaining_str = "" then None else Some remaining_str
        in
        let ref_id = if first then reply_to_message_id else None in
        match Discord_rest_client.send_message ~token ~channel_id ~content:chunk ?reply_to_message_id:ref_id () with
        | Ok id ->
            (match remaining with
             | None -> Ok id
             | Some next -> send_chunks false next)
        | Error e -> Error (Rest_error e)
      in
      send_chunks true content

let edit_message ~channel_id ~message_id ~content () =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
      (match
         Discord_rest_client.edit_message ~token ~channel_id ~message_id
           ~content ()
       with
       | Ok () -> Ok ()
       | Error e -> Error (Rest_error e))

let trigger_typing ~channel_id () =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
      (match Discord_rest_client.trigger_typing ~token ~channel_id () with
       | Ok () -> Ok ()
       | Error e -> Error (Rest_error e))
