(* Channel_gate_slack_state — Slack in-process connector state (RFC-0317).

   Implements {!Channel_gate_connector.S} so it can be registered at server
   startup via [Channel_gate_connector.register (module Channel_gate_slack_state)].

   The in-process Slack gateway ({!Slack_socket_client}, RFC-0317 PR-1) is the
   only Slack transport; the Python sidecar is removed in PR-4. Mirrors
   {!Channel_gate_discord_state} but is simpler — no threads (Slack threads
   share the parent channel id; a [thread_ts] is not a separate channel), no
   typing indicator (Slack's is a separate Web API we don't surface yet). *)

module Store = Channel_gate_binding_store

type binding = Store.binding = {
  channel_id : string;
  keeper_name : string;
}

let connector_id = "slack"
let display_name = "Slack"
let channel = "slack"

let default_status_path = ".gate/runtime/slack/status.json"
let default_binding_store_path = ".gate/runtime/slack/bindings.json"
let default_binding_audit_path = ".gate/runtime/slack/binding_audit.jsonl"

(* Slack has no Discord-style guilds; the bot token authorizes per-workspace.
   Path resolvers read an env override, else fall back to the default. *)
let resolve_path raw_path =
  if Filename.is_relative raw_path then
    Filename.concat (Env_config_core.base_path ()) raw_path
  else raw_path

let slack_path ~env_var ~default () =
  match Env_config_core.raw_value_opt env_var |> Env_config_core.trim_opt with
  | Some path -> resolve_path path
  | None -> resolve_path default

let status_path () =
  slack_path ~env_var:"MASC_SLACK_STATUS_PATH" ~default:default_status_path ()

let binding_store_path () =
  slack_path ~env_var:"MASC_SLACK_BINDING_STORE_PATH"
    ~default:default_binding_store_path ()

let binding_audit_path () =
  slack_path ~env_var:"MASC_SLACK_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path ()

(* Slack has no guild concept, so audit events omit guild_id. *)
let binding_store =
  Store.create
    ~binding_store_path ~binding_store_read_path:binding_store_path
    ~binding_audit_path ~binding_audit_read_path:binding_audit_path
    ~guild_id_field:Store.Omit

let read_bindings () = Store.read_bindings binding_store
let read_bindings_result () = Store.read_bindings_result binding_store
let binding_json = Store.binding_json
let save_bindings bindings = Store.save_bindings binding_store bindings
let append_audit_event event = Store.append_audit_event binding_store event
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

let stale_after_sec () =
  Env_config_core.get_int ~default:30 "MASC_SLACK_STATUS_STALE_SEC"

(* Trigger policy registry — set once at gateway startup, read for dashboard. *)
let trigger_policy_ref : Slack_gateway_state.trigger_policy option ref =
  ref None

let set_trigger_policy (p : Slack_gateway_state.trigger_policy) =
  trigger_policy_ref := Some p

let get_trigger_policy () = !trigger_policy_ref

let connector_state_label ~available ~connected ~stale =
  if not available then "offline"
  else if stale then "stale"
  else if connected then "connected"
  else "disconnected"

(* Outbound REST uses the bot token (xoxb-...). The app token (xapp-...) is read
   only by {!Slack_socket_client} for apps.connections.open. Both resolve
   through the config boundary ({!Env_config_slack}) so the token env names
   ([SLACK_BOT_TOKEN] / [SLACK_APP_TOKEN]) are defined in exactly one place and
   cannot drift between this state module and the gateway. *)
let bot_token_opt = Env_config_slack.bot_token_opt
let app_token_opt = Env_config_slack.app_token_opt

let gateway_state_label = function
  | Slack_gateway_state.Disconnected -> "disconnected"
  | Awaiting_hello -> "awaiting_hello"
  | Connected -> "connected"
  | Reconnect_pending _ -> "reconnect_pending"
  | Failed _ -> "failed"

(* Bot identity. Slack has no READY dispatch; [record_ready] is called from the
   gateway's hello handler once the bot user id is known. *)
type ready_info = {
  ready_bot_user_id : string;
  ready_at : string;
}

let last_ready : ready_info option Atomic.t = Atomic.make None
let startup_error : string option Atomic.t = Atomic.make None

let record_startup_error message = Atomic.set startup_error (Some message)
let clear_startup_error () = Atomic.set startup_error None

let record_ready ~bot_user_id =
  Atomic.set last_ready
    (Some
       { ready_bot_user_id = bot_user_id
       ; (* NDT-OK: hello wall-clock is operator-facing telemetry only. *)
         ready_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) })

let status_json ?(audit_limit = 10) () =
  let gateway_state = Slack_socket_client.connection_state () in
  let startup_error = Atomic.get startup_error in
  let bot_present = Option.is_some (bot_token_opt ()) in
  let app_present = Option.is_some (app_token_opt ()) in
  (* Socket Mode needs the app token; without it the gateway never starts. *)
  let startup_ok = Option.is_none startup_error in
  let available = app_present && startup_ok in
  let connected =
    startup_ok
    && match gateway_state with
       | Connected -> true
       | Disconnected | Awaiting_hello | Reconnect_pending _ | Failed _ -> false
  in
  let stale = false in
  (* NDT-OK: status_json is a dashboard observation boundary; this timestamp
     reports gateway freshness and is not used for control flow. *)
  let updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  let error =
    match startup_error with
    | Some message -> message
    | None ->
      (match gateway_state with
       | Disconnected ->
         if app_present then "" else "SLACK_APP_TOKEN is unset or empty"
       | Failed msg -> msg
       | Awaiting_hello | Connected | Reconnect_pending _ -> "")
  in
  let configured_bindings = read_bindings () in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  let configured_binding_json = List.map binding_json configured_bindings in
  `Assoc
    [ ("channel", `String channel)
    ; ("capabilities", Channel_gate_connector_capability.all_json)
    ; ("available", `Bool available)
    ; ("connected", `Bool connected)
    ; ("stale", `Bool stale)
    ; ("stale_after_sec", `Int (stale_after_sec ()))
    ; ("status", `String (connector_state_label ~available ~connected ~stale))
    ; ("error", `String error)
    ; ("status_source", `String "in_process_gateway")
    ; ("gateway_state", `String (gateway_state_label gateway_state))
    ; ("status_path", `String (status_path ()))
    ; ("binding_store_path", `String (binding_store_path ()))
    ; ("audit_path", `String (binding_audit_path ()))
    ; ("binding_source", `String "persisted")
    ; ("runtime_bindings_count", `Int (List.length configured_bindings))
    ; ("configured_bindings", `List configured_binding_json)
    ; ("recent_audit", `List recent_audit)
    ; ("bindings", `List configured_binding_json)
    ; ("audit", `List recent_audit)
    ; ("bot_token_present", `Bool bot_present)
    ; ("app_token_present", `Bool app_present)
    ; ("updated_at", `String updated_at)
    ; ( "last_ready_at"
      , `String
          (match Atomic.get last_ready with
           | Some r -> r.ready_at
           | None -> "") )
    ; ( "bot_user_id"
      , `String
          (match Atomic.get last_ready with
           | Some r -> r.ready_bot_user_id
           | None -> "") )
    ]

let connector_json ?gate_status_json ?(audit_limit = 10) () =
  let status = status_json ~audit_limit () in
  let base =
    match gate_status_json with
    | None -> status
    | Some extra ->
      `Assoc
        (match (status, extra) with
         | `Assoc s, `Assoc e -> s @ e
         | _ -> [ ("status", status); ("gate_status", extra) ])
  in
  (* The dashboard connectors endpoint
     ([Channel_gate_connector.connectors_json]) matches each connector to its
     tile by [connector_id]; the dashboard's [findConnector(connectors,
     "slack")] returns null without it, so a connected Slack gateway rendered
     as an unstarted "설정 필요" placeholder. Mirror Discord/Telegram
     [connector_json], which carry both identity fields at the top level.
     Prepend (with a dedupe filter) so the identity is authoritative even if a
     merged [gate_status_json] also supplied the keys. *)
  match base with
  | `Assoc fields ->
    let without_identity =
      List.filter
        (fun (k, _) ->
          not
            (String.equal k "connector_id" || String.equal k "display_name"))
        fields
    in
    `Assoc
      (("connector_id", `String connector_id)
      :: ("display_name", `String display_name)
      :: without_identity)
  | other -> other

let rollback_bindings original = save_bindings original

let bind ~channel_id ~keeper_name ~actor_name =
  let channel_id = String.trim channel_id in
  let keeper_name = String.trim keeper_name in
  if String.equal channel_id "" then Error "channel_id is required"
  else if String.equal keeper_name "" then Error "keeper_name is required"
  else
    match read_bindings_result () with
    | Error msg -> Error msg
    | Ok original_bindings ->
      let previous_keeper =
        match
          List.find_map
            (fun (b : binding) ->
              if String.equal b.channel_id channel_id then Some b.keeper_name
              else None)
            original_bindings
        with
        | Some keeper_name -> keeper_name
        | None -> ""
      in
      let updated_bindings =
        (({ channel_id; keeper_name } : binding)
         :: List.filter
              (fun (b : binding) ->
                not (String.equal b.channel_id channel_id))
              original_bindings)
        |> List.sort (fun (a : binding) (b : binding) ->
               String.compare a.channel_id b.channel_id)
      in
      try
        save_bindings updated_bindings;
        append_audit_event
          Store.
            { timestamp =
                (* NDT-OK: binding audit wall-clock is operator-facing
                   telemetry only. *)
                Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())
            ; action = "bind"
            ; guild_id = None
            ; channel_id
            ; keeper_name
            ; actor_id = actor_name
            ; actor_name
            ; previous_keeper };
        Ok (status_json ())
      with Sys_error msg -> rollback_bindings original_bindings; Error msg

let unbind ~channel_id ~actor_name =
  let channel_id = String.trim channel_id in
  if String.equal channel_id "" then Error "channel_id is required"
  else
    match read_bindings_result () with
    | Error msg -> Error msg
    | Ok original_bindings -> (
      match
        original_bindings
        |> List.find_opt (fun (b : binding) ->
               String.equal b.channel_id channel_id)
      with
      | None -> Error "binding not found"
      | Some (removed : binding) ->
        let updated_bindings =
          List.filter
            (fun (b : binding) ->
              not (String.equal b.channel_id channel_id))
            original_bindings
        in
        try
          save_bindings updated_bindings;
          append_audit_event
            Store.
              { timestamp =
                  (* NDT-OK: binding audit wall-clock is operator-facing
                     telemetry only. *)
                  Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())
              ; action = "unbind"
              ; guild_id = None
              ; channel_id
              ; keeper_name = removed.keeper_name
              ; actor_id = actor_name
              ; actor_name
              ; previous_keeper = removed.keeper_name };
          Ok (status_json ())
        with Sys_error msg -> rollback_bindings original_bindings; Error msg)

(* ---- In-process gateway support (replaces sidecars/slack-bot/) ---- *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

let binding_for_channel bindings ~channel_id =
  List.find_map
    (fun (b : binding) ->
      if String.equal b.channel_id channel_id then Some b else None)
    bindings

(* Slack threads share the parent channel id (a thread_ts is a message
   timestamp, not a channel), so resolution is a single exact lookup — no
   thread→parent fallback like Discord. *)
let resolve_keeper_for_channel_result ~channel_id =
  let normalized = String.trim channel_id in
  if String.equal normalized "" then Ok None
  else
    match read_bindings_result () with
    | Error msg -> Error msg
    | Ok candidates -> (
      match binding_for_channel candidates ~channel_id:normalized with
      | Some b ->
        Ok
          (Some
             { keeper_name = b.keeper_name
             ; incoming_channel_id = normalized
             ; bound_channel_id = b.channel_id
             ; via_parent = false })
      | None -> Ok None)

let resolve_keeper_for_channel ~channel_id =
  let normalized = String.trim channel_id in
  match resolve_keeper_for_channel_result ~channel_id:normalized with
  | Ok resolution -> resolution
  | Error msg ->
    if not (String.equal normalized "") then
      Log.Slack.warn "slack binding lookup failed for channel_id=%s: %s"
        normalized msg;
    None

let keeper_for_channel ~channel_id =
  match resolve_keeper_for_channel ~channel_id with
  | None -> None
  | Some resolution -> Some resolution.keeper_name

(* RFC-0223 P2 presence surface. Recomputed per call — no cached state. *)
let bound_channels ~keeper_name =
  let normalized = String.trim keeper_name in
  if String.equal normalized "" then []
  else
    read_bindings ()
    |> List.filter_map (fun (b : binding) ->
           if String.equal b.keeper_name normalized then Some b.channel_id
           else None)

let connected () =
  (* The in-process gateway (RFC-0317) is the only Slack transport; its run
     loop publishes the typed connection state. *)
  match Slack_socket_client.connection_state () with
  | Slack_gateway_state.Connected -> true
  | Disconnected | Awaiting_hello | Reconnect_pending _ | Failed _ -> false

(* ---- Outbound REST (delegates to Slack_rest_client with the bot token) ---- *)

type send_error =
  | Missing_token
  | Rest_error of Slack_rest_client.error

let pp_send_error fmt = function
  | Missing_token ->
    Format.fprintf fmt "SLACK_BOT_TOKEN is unset or empty"
  | Rest_error e ->
    Format.fprintf fmt "slack rest error: %a" Slack_rest_client.pp_error e

let send_message ?clock ?timeout_sec ~channel_id ~content ?reply_to_message_id ()
    =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
    (match
       Slack_rest_client.send_message ?clock ?timeout_sec ~token ~channel_id
         ~text:content ?thread_ts:reply_to_message_id ()
     with
     | Ok ts -> Ok ts
     | Error e -> Error (Rest_error e))

let edit_message ?clock ?timeout_sec ~channel_id ~message_id ~content () =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
    (match
       Slack_rest_client.edit_message ?clock ?timeout_sec ~token ~channel_id
         ~ts:message_id ~text:content ()
     with
     | Ok () -> Ok ()
     | Error e -> Error (Rest_error e))
