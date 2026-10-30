(* Channel_gate_slack_state — Slack in-process connector state (RFC-0317).

   Implements {!Channel_gate_connector.S} so it can be registered at server
   startup via [Channel_gate_connector.register (module Channel_gate_slack_state)].

   The in-process Slack gateway ({!Slack_socket_client}, RFC-0317) is the
   only Slack transport. Mirrors
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

let default_binding_store_path = ".gate/runtime/slack/bindings.json"
let default_binding_audit_path = ".gate/runtime/slack/binding_audit.jsonl"

(* Slack has no Discord-style guilds; the bot token authorizes per-workspace.
   Path resolvers read an env override, else fall back to the default. *)
let slack_path ~env_var ~default () =
  match Env_config_core.raw_value_opt env_var |> Env_config_core.trim_opt with
  | Some path -> Env_config_core.resolve_against_base_path path
  | None -> Env_config_core.resolve_against_base_path default

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

let read_bindings_result () = Store.read_bindings_result binding_store
let binding_json = Store.binding_json
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

(* The one definition of "the transport is live", used both by [status_json]
   and by the [Channel_gate_connector.S] registry export [connected]. Startup
   and binding-store health are not part of it; they have their own fields
   ([error], [binding_store_read_ok]) and their own effect on [available]. It
   takes the state rather than reading it, so a status reading that already
   holds the state does not read it again. *)
let gateway_connected = function
  | Slack_gateway_state.Connected -> true
  | Disconnected | Awaiting_hello | Reconnect_pending _ | Failed _ -> false

(* Outbound REST uses the bot token (xoxb-...). The app token (xapp-...) is read
   only by {!Slack_socket_client} for apps.connections.open. Both resolve
   through the config boundary ({!Env_config_slack}) so the token env names
   ([SLACK_BOT_TOKEN] / [SLACK_APP_TOKEN]) are defined in exactly one place and
   cannot drift between this state module and the gateway. *)
let bot_token_opt = Env_config_slack.bot_token_opt
let app_token_opt = Env_config_slack.app_token_opt

(* Why the connector cannot do its job, as a closed sum. Slack needs both
   credentials and they fail differently: without SLACK_APP_TOKEN the Socket
   Mode gateway never starts, and without SLACK_BOT_TOKEN it starts and
   receives but every reply fails ([send_message] returns [Missing_token]).
   A connector that cannot answer is not available, so both are part of the
   verdict. [Connector_unavailable] carries the config boundary's own
   operator-facing reason (disabled, or an invalid [slack] section); the
   tokens are suppressed in that state, so it is checked first. *)
type credential_error =
  | Connector_unavailable of string
  | Missing_app_token
  | Missing_bot_token

let credential_error_message = function
  | Connector_unavailable reason -> reason
  | Missing_app_token -> "SLACK_APP_TOKEN is unset or empty"
  | Missing_bot_token ->
    "SLACK_BOT_TOKEN is unset or empty: inbound connects but every outbound \
     chat.postMessage fails"

let credential_error_of_presence ~app_present ~bot_present =
  match Env_config_slack.unavailable_reason () with
  | Some reason -> Some (Connector_unavailable reason)
  | None ->
    if not app_present then Some Missing_app_token
    else if not bot_present then Some Missing_bot_token
    else None

let credential_error () =
  credential_error_of_presence
    ~app_present:(Option.is_some (app_token_opt ()))
    ~bot_present:(Option.is_some (bot_token_opt ()))

let gateway_state_label = function
  | Slack_gateway_state.Disconnected -> "disconnected"
  | Awaiting_hello -> "awaiting_hello"
  | Connected -> "connected"
  | Reconnect_pending _ -> "reconnect_pending"
  | Failed _ -> "failed"

(* Bot identity. Slack has no READY dispatch; [record_ready] is called from the
   gateway's hello handler once the bot user id is known. *)
type ready_info = Channel_gate_connector.ready_info

let last_ready : ready_info option Atomic.t = Atomic.make None
let workspace_id : string option Atomic.t = Atomic.make None
let startup_error : string option Atomic.t = Atomic.make None

let record_startup_error message = Atomic.set startup_error (Some message)
let clear_startup_error () = Atomic.set startup_error None

let record_ready ~bot_user_id =
  Atomic.set last_ready
    (Some
       { ready_bot_user_id = bot_user_id
       ; (* NDT-OK: hello wall-clock is operator-facing telemetry only. *)
         ready_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) })

let record_workspace_id value =
  let value = String.trim value in
  if not (String.equal value "") then Atomic.set workspace_id (Some value)

let current_workspace_id () = Atomic.get workspace_id
let clear_workspace_id () = Atomic.set workspace_id None

(* One reading of the connector, rendered by [status_json] and
   [connector_json] alike so the two views cannot disagree. Values computed
   from other fields ([connected] from [gateway_state], [pid] from
   [available]) are computed at render time, not stored beside their source. *)
type status = {
  gateway_state : Slack_gateway_state.connection_state;
  trigger_policy : Slack_gateway_state.trigger_policy;
  available : bool;
  error : string;
  binding_store_path : string;
  audit_path : string;
  binding_store_read_ok : bool;
  binding_store_error : string;
  configured_bindings : binding list;
  recent_audit : Yojson.Safe.t list;
  bot_token_present : bool;
  app_token_present : bool;
  updated_at : string;
  last_ready : ready_info option;
}

let read_status ~audit_limit =
  let gateway_state = Slack_socket_client.connection_state () in
  let startup_error = Atomic.get startup_error in
  let bot_present = Option.is_some (bot_token_opt ()) in
  let app_present = Option.is_some (app_token_opt ()) in
  (* Socket Mode needs the app token; without it the gateway never starts. *)
  let startup_ok = Option.is_none startup_error in
  let configured_bindings_result = read_bindings_result () in
  let binding_store_read_ok = Result.is_ok configured_bindings_result in
  let configured_bindings, binding_store_error =
    match configured_bindings_result with
    | Ok bindings -> bindings, ""
    | Error error -> [], Store.binding_store_error_to_string error
  in
  let credential_error =
    credential_error_of_presence ~app_present ~bot_present
  in
  let available =
    app_present && bot_present && startup_ok && binding_store_read_ok
  in
  (* NDT-OK: status_json is a dashboard observation boundary; this timestamp
     reports gateway freshness and is not used for control flow. *)
  let updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  (* A recorded startup error is why the gateway is not running; the rest is
     downstream of it, so it stays the whole message. Otherwise report every
     independent reason at once rather than letting one mask the others. *)
  let error =
    match startup_error with
    | Some message -> message
    | None ->
      [ (if binding_store_read_ok then None else Some binding_store_error)
      ; (match gateway_state with
         | Failed msg -> Some msg
         | Disconnected | Awaiting_hello | Connected | Reconnect_pending _ ->
           None)
      ; Option.map credential_error_message credential_error
      ]
      |> List.filter_map Fun.id
      |> String.concat "; "
  in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  {
    gateway_state;
    trigger_policy = Runtime_params.get Connector_trigger_params.slack;
    available;
    error;
    binding_store_path = binding_store_path ();
    audit_path = binding_audit_path ();
    binding_store_read_ok;
    binding_store_error;
    configured_bindings;
    recent_audit;
    bot_token_present = bot_present;
    app_token_present = app_present;
    updated_at;
    last_ready = Atomic.get last_ready;
  }

(* The fields both views share, written once so a field added to one view
   is in the other too. *)
let status_fields status =
  [ ("channel", `String channel)
  ; ("capabilities", Channel_gate_connector_capability.all_json)
  ; ("trigger_policy",
     `String (Slack_gateway_state.trigger_policy_to_string status.trigger_policy))
  ; ("available", `Bool status.available)
  ; ("connected", `Bool (gateway_connected status.gateway_state))
  ; ("status",
     `String
       (* The gateway state machine is the liveness source; it has no
          heartbeat file that could age out, so it is never stale. *)
       (Channel_gate_connector.connector_state_label
          ~available:status.available
          ~connected:(gateway_connected status.gateway_state)
          ~stale:false))
  ; ("error", `String status.error)
  ; ("status_source", `String "in_process_gateway")
  ; ("gateway_state", `String (gateway_state_label status.gateway_state))
  ; ("binding_store_path", `String status.binding_store_path)
  ; ("audit_path", `String status.audit_path)
  ; ("binding_source", `String "persisted")
  ; ("binding_store_read_ok", `Bool status.binding_store_read_ok)
  ; ("binding_store_error", `String status.binding_store_error)
  ; ("runtime_bindings_count", `Int (List.length status.configured_bindings))
  ; ("configured_bindings", `List (List.map binding_json status.configured_bindings))
  ; ("recent_audit", `List status.recent_audit)
  ; ("bot_token_present", `Bool status.bot_token_present)
  ; ("app_token_present", `Bool status.app_token_present)
  ; ("updated_at", `String status.updated_at)
  ; ( "last_ready_at"
    , `String
        (match status.last_ready with
         | Some r -> r.ready_at
         | None -> "") )
  ; ( "bot_user_id"
    , `String
        (match status.last_ready with
         | Some r -> r.ready_bot_user_id
         | None -> "") )
  ; ("pid", `Int (if status.available then Unix.getpid () else 0))
  ]

let status_json ?(audit_limit = 10) () =
  `Assoc (status_fields (read_status ~audit_limit))

let connector_json ?(audit_limit = 10) () =
  `Assoc
    (("connector_id", `String connector_id)
     :: ("display_name", `String display_name)
     :: status_fields (read_status ~audit_limit))

let bind ~channel_id ~keeper_name ~actor_name =
  Store.bind binding_store ~channel_id ~keeper_name ~actor_name
  |> Result.map_error Store.mutation_error_to_string
  |> Result.map (fun () -> status_json ())

let unbind_internal ?expected_keeper_name ~channel_id ~actor_name () =
  Store.unbind binding_store ?expected_keeper_name ~channel_id ~actor_name ()
  |> Result.map_error Store.mutation_error_to_string
  |> Result.map (fun () -> status_json ())

let unbind ~channel_id ~actor_name =
  unbind_internal ~channel_id ~actor_name ()

let unbind_if_keeper ~channel_id ~expected_keeper_name ~actor_name =
  unbind_internal ~expected_keeper_name ~channel_id ~actor_name ()

(* ---- In-process gateway support ---- *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

(* Slack threads share the parent channel id (a thread_ts is a message
   timestamp, not a channel), so resolution is a single exact lookup — no
   thread→parent fallback like Discord. *)
let resolve_keeper_for_channel_result ~channel_id =
  let normalized = String.trim channel_id in
  if String.equal normalized "" then Ok None
  else
    match read_bindings_result () with
    | Error error -> Error error
    | Ok candidates -> (
      match
        Store.find_binding_by_channel_id candidates ~channel_id:normalized
      with
      | Some b ->
        Ok
          (Some
             { keeper_name = b.keeper_name
             ; incoming_channel_id = normalized
             ; bound_channel_id = b.channel_id
             ; via_parent = false })
      | None -> Ok None)

(* RFC-0223 P2 presence surface. Recomputed per call — no cached state. *)
let bound_channels ~keeper_name =
  Store.bound_channels_result binding_store ~keeper_name

let connected () =
  (* The in-process gateway (RFC-0317) is the only Slack transport; its run
     loop publishes the typed connection state. Same definition [status_json]
     reports — see [gateway_connected]. *)
  gateway_connected (Slack_socket_client.connection_state ())

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
