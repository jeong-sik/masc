module U = Yojson.Safe.Util
module Store = Channel_gate_binding_store

type binding = Store.binding = {
  channel_id : string;
  keeper_name : string;
}

let connector_id = "discord"
let display_name = "Discord"
let channel = "discord"


let default_binding_store_path = ".gate/runtime/discord/bindings.json"
let default_binding_audit_path = ".gate/runtime/discord/binding_audit.jsonl"

(* [raw_value_opt] rather than [Sys.getenv_opt]: it falls back to the
   boot-time config overrides, so a path declared in runtime.toml is seen the
   way every other MASC setting is (#21972 P2-1). *)
let configured_write_path env_name ~default =
  match Env_config_core.raw_value_opt env_name |> Env_config_core.trim_opt with
  | Some raw -> Env_config_core.resolve_against_base_path raw
  | None -> Env_config_core.resolve_against_base_path default

let binding_store_path () =
  configured_write_path "MASC_DISCORD_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_store_read_path () =
  configured_write_path "MASC_DISCORD_BINDING_STORE_PATH"
    ~default:default_binding_store_path

let binding_audit_path () =
  configured_write_path "MASC_DISCORD_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

let binding_audit_read_path () =
  configured_write_path "MASC_DISCORD_BINDING_AUDIT_PATH"
    ~default:default_binding_audit_path

(* [Include_empty], not [Omit]: the audit wire shape carries a [guild_id]
   key for Discord rows and the dashboard reads that shape. Nothing resolves
   guild ids, so the constant-empty field is declared at the store level
   instead of resolved per event. *)
let binding_store =
  Store.create ~binding_store_path ~binding_store_read_path ~binding_audit_path
    ~binding_audit_read_path ~guild_id_field:Store.Include_empty

let read_bindings_result () = Store.read_bindings_result binding_store
let binding_json = Store.binding_json
let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

type binding_lookup_error =
  | Binding_store_read_failed of Store.binding_store_error

let pp_binding_lookup_error formatter = function
  | Binding_store_read_failed detail ->
    Format.fprintf
      formatter
      "Discord binding store read failed: %s"
      (Store.binding_store_error_to_string detail)

let binding_lookup_error_to_string error =
  Format.asprintf "%a" pp_binding_lookup_error error

let read_bindings_lookup_result () =
  read_bindings_result ()
  |> Result.map_error (fun detail -> Binding_store_read_failed detail)

let configured_channel_ids_result () =
  read_bindings_lookup_result ()
  |> Result.map (List.map (fun (binding : binding) -> binding.channel_id))

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

let bot_token_opt () = Env_config_discord.bot_token_opt ()

let gateway_state_label = function
  | Discord_gateway_state.Disconnected -> "disconnected"
  | Awaiting_hello -> "awaiting_hello"
  | Identifying -> "identifying"
  | Resuming -> "resuming"
  | Connected _ -> "connected"
  | Reconnect_pending _ -> "reconnect_pending"
  | Failed _ -> "failed"

(* Bot identity captured from the gateway's READY dispatch; the in-process
   gateway (RFC-0203) keeps it in memory. *)
type ready_info = Channel_gate_connector.ready_info

let last_ready : ready_info option Atomic.t = Atomic.make None
let last_bot_user_name : string option Atomic.t = Atomic.make None
let current_guild_ids_ref : string list Atomic.t = Atomic.make []

let record_ready ~bot_user_id ~bot_user_name ~guild_ids =
  Atomic.set last_ready
    (Some
       {
         ready_bot_user_id = bot_user_id;
         (* NDT-OK: READY wall-clock is operator-facing telemetry only
            (status_json last_ready_at); no control flow reads it. *)
         ready_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
       });
  Atomic.set last_bot_user_name bot_user_name;
  Atomic.set current_guild_ids_ref guild_ids

let current_guild_ids () = Atomic.get current_guild_ids_ref

type directory_phase =
  | Directory_not_started
  | Directory_refreshing
  | Directory_complete
  | Directory_partial

type directory_observation = {
  phase : directory_phase;
  server_count : int;
  channel_count : int;
  person_count : int;
  authentication_failed : string list;
  permission_denied : string list;
  errors : string list;
  updated_at : string option;
}

let directory_observation : directory_observation Atomic.t =
  Atomic.make
    { phase = Directory_not_started
    ; server_count = 0
    ; channel_count = 0
    ; person_count = 0
    ; authentication_failed = []
    ; permission_denied = []
    ; errors = []
    ; updated_at = None
    }

let record_directory_refresh_started () =
  let previous = Atomic.get directory_observation in
  Atomic.set directory_observation { previous with phase = Directory_refreshing }

let record_directory_refresh_finished ~server_count ~channel_count ~person_count
    ~authentication_failed ~permission_denied ~errors =
  let authentication_failed =
    List.sort_uniq String.compare authentication_failed
  in
  let permission_denied = List.sort_uniq String.compare permission_denied in
  let errors = List.sort_uniq String.compare errors in
  Atomic.set directory_observation
    { phase =
        (if authentication_failed = [] && permission_denied = [] && errors = []
         then Directory_complete
         else Directory_partial)
    ; server_count
    ; channel_count
    ; person_count
    ; authentication_failed
    ; permission_denied
    ; errors
    ; updated_at = Some (Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()))
    }

let directory_phase_label = function
  | Directory_not_started -> "not_started"
  | Directory_refreshing -> "refreshing"
  | Directory_complete -> "complete"
  | Directory_partial -> "partial"

let status_json ?(audit_limit = 10) () =
  let binding_store_path = binding_store_read_path () in
  let audit_path = binding_audit_read_path () in
  let configured_bindings_result = read_bindings_lookup_result () in
  let configured_bindings = Result.value ~default:[] configured_bindings_result in
  let binding_store_error =
    match configured_bindings_result with
    | Ok _ -> None
    | Error error -> Some (binding_lookup_error_to_string error)
  in
  let recent_audit = read_recent_audit ~limit:audit_limit in
  let channel = "discord" in
  let gateway_state = Discord_gateway_client.connection_state () in
  let token_present = Option.is_some (bot_token_opt ()) in
  let transport_available =
    match gateway_state with
    | Disconnected -> token_present
    | Awaiting_hello | Identifying | Resuming | Connected _
    | Reconnect_pending _ | Failed _ -> true
  in
  let available = transport_available && Result.is_ok configured_bindings_result in
  let connected =
    match gateway_state with
    | Connected _ -> true
    | Disconnected | Awaiting_hello | Identifying | Resuming
    | Reconnect_pending _ | Failed _ -> false
  in
  (* NDT-OK: status_json is a dashboard observation boundary; this timestamp
     only reports gateway freshness and is not used for control flow. *)
  let updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  let gateway_error =
    match gateway_state with
    | Disconnected ->
      if token_present then "" else "DISCORD_BOT_TOKEN is unset or empty"
    | Failed msg -> msg
    | Awaiting_hello | Identifying | Resuming | Connected _
    | Reconnect_pending _ -> ""
  in
  let error =
    [ (if String.equal gateway_error "" then None else Some gateway_error)
    ; binding_store_error
    ]
    |> List.filter_map Fun.id
    |> String.concat "; "
  in
  let directory = Atomic.get directory_observation in
  `Assoc
    [
      ("channel", `String channel);
      ("available", `Bool available);
      ("connected", `Bool connected);
      ( "status",
        `String
          (* The gateway state machine is the liveness source; it has no
             heartbeat file that could age out, so it is never stale. *)
          (Channel_gate_connector.connector_state_label ~available ~connected
             ~stale:false) );
      ("error", `String error);
      ("bot_token_present", `Bool token_present);
      ("status_source", `String "in_process_gateway");
      ("gateway_state", `String (gateway_state_label gateway_state));
      ("trigger_policy", trigger_policy_json ());
      ("binding_store_path", `String binding_store_path);
      ("audit_path", `String audit_path);
      ("updated_at", `String updated_at);
      ( "last_ready_at",
        (* The READY timestamp survives reconnect_pending/resuming dips,
           so operators can tell "was up, recovering" from "never came
           up" — current liveness is gateway_state above. *)
        `String
          (match Atomic.get last_ready with
           | Some { ready_at; _ } -> ready_at
           | None -> "") );
      ( "bot_user_name",
        `String (Option.value ~default:"" (Atomic.get last_bot_user_name)) );
      ( "bot_user_id",
        `String
          (match Atomic.get last_ready with
           | Some { ready_bot_user_id; _ } -> ready_bot_user_id
           | None -> "") );
      ("guild_count", `Int (List.length (current_guild_ids ())));
      ("directory_state", `String (directory_phase_label directory.phase));
      ("directory_server_count", `Int directory.server_count);
      ("directory_channel_count", `Int directory.channel_count);
      ("directory_person_count", `Int directory.person_count);
      ( "directory_authentication_failed",
        `List
          (List.map (fun value -> `String value)
             directory.authentication_failed) );
      ( "directory_permission_denied",
        `List (List.map (fun value -> `String value) directory.permission_denied) );
      ("directory_errors", `List (List.map (fun value -> `String value) directory.errors));
      ( "directory_updated_at",
        `String (Option.value ~default:"" directory.updated_at) );
      ("gate_base_url", `String "in-process");
      ("gate_healthy", if connected then `Bool true else `Null);
      ("gate_health_checked_at", `String (if connected then updated_at else ""));
      ("binding_source", `String "persisted");
      ("binding_store_read_ok", `Bool (Result.is_ok configured_bindings_result));
      ( "binding_store_error",
        `String (Option.value ~default:"" binding_store_error) );
      ("runtime_bindings_count", `Int (List.length configured_bindings));
      (* NDT-OK: pid is process identity telemetry for operators; availability
         and connection status come from the gateway state above. *)
      ("pid", `Int (if available then Unix.getpid () else 0));
      ( "configured_bindings",
        `List (List.map binding_json configured_bindings) );
      ("recent_audit", `List recent_audit);
    ]

let connector_json ?(audit_limit = 10) () =
  let status = status_json ~audit_limit () in
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
      ("status_source", status |> U.member "status_source");
      ("gateway_state", status |> U.member "gateway_state");
      ("error", `String (string_member status "error"));
      ("bot_token_present", status |> U.member "bot_token_present");
      ("binding_store_path", `String (string_member status "binding_store_path"));
      ("binding_store_read_ok", status |> U.member "binding_store_read_ok");
      ("binding_store_error", status |> U.member "binding_store_error");
      ("audit_path", `String (string_member status "audit_path"));
      ("names_path", `String (string_member status "names_path"));
      ("names", status |> U.member "names");
      ("updated_at", `String (string_member status "updated_at"));
      ("last_ready_at", `String (string_member status "last_ready_at"));
      ("bot_user_name", `String (string_member status "bot_user_name"));
      ("bot_user_id", `String (string_member status "bot_user_id"));
      ("guild_count", `Int (int_member status "guild_count"));
      ("directory_state", status |> U.member "directory_state");
      ("directory_server_count", status |> U.member "directory_server_count");
      ("directory_channel_count", status |> U.member "directory_channel_count");
      ("directory_person_count", status |> U.member "directory_person_count");
      ( "directory_authentication_failed",
        status |> U.member "directory_authentication_failed" );
      ( "directory_permission_denied",
        status |> U.member "directory_permission_denied" );
      ("directory_errors", status |> U.member "directory_errors");
      ("directory_updated_at", status |> U.member "directory_updated_at");
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
    ]

let bind ~channel_id ~keeper_name ~actor_name =
  let channel_id = String.trim channel_id in
  let keeper_name = String.trim keeper_name in
  if channel_id = "" then
    Error "channel_id is required"
  else if keeper_name = "" then
    Error "keeper_name is required"
  else
    Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
      let previous_keeper =
        original_bindings
        |> List.find_map (fun (binding : binding) ->
             if String.equal binding.channel_id channel_id then
               Some binding.keeper_name
             else None)
        |> function
        | Some keeper_name -> keeper_name
        | None ->
          (* DET-OK: the audit wire contract uses an empty string to represent
             that this channel had no previous binding; it does not affect the
             mutation decision. *)
          ""
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
      Ok
        ( updated_bindings
        , Store.{
            (* NDT-OK: wall-clock time is persisted as operator-facing audit
               evidence only; mutation ordering comes from the durable lock. *)
            timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
            action = "bind";
            channel_id;
            keeper_name;
            actor_id = actor_name;
            actor_name;
            previous_keeper;
          }
        , () ))
    |> Result.map_error Store.mutation_error_to_string
    |> Result.map (fun () -> status_json ())

let unbind_internal ?expected_keeper_name ~channel_id ~actor_name =
  let channel_id = String.trim channel_id in
  if channel_id = "" then
    Error "channel_id is required"
  else
    Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
      match
        original_bindings
        |> List.find_opt (fun (binding : binding) ->
             String.equal binding.channel_id channel_id)
      with
      | None -> Error "binding not found"
      | Some (removed_binding : binding)
        when (match expected_keeper_name with
              | Some expected ->
                not (String.equal expected removed_binding.keeper_name)
              | None -> false) ->
        Error "binding changed"
      | Some (removed_binding : binding) ->
        let updated_bindings =
          List.filter
            (fun (binding : binding) ->
              not (String.equal binding.channel_id channel_id))
            original_bindings
        in
        Ok
          ( updated_bindings
          , Store.{
              (* NDT-OK: wall-clock time is persisted as operator-facing audit
                 evidence only; mutation ordering comes from the durable lock. *)
              timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
              action = "unbind";
              channel_id;
              keeper_name = removed_binding.keeper_name;
              actor_id = actor_name;
              actor_name;
              previous_keeper = removed_binding.keeper_name;
            }
          , () ))
    |> Result.map_error Store.mutation_error_to_string
    |> Result.map (fun () -> status_json ())

let unbind ~channel_id ~actor_name =
  unbind_internal ?expected_keeper_name:None ~channel_id ~actor_name

let unbind_if_keeper ~channel_id ~expected_keeper_name ~actor_name =
  unbind_internal ~expected_keeper_name ~channel_id ~actor_name

(* ---------------------------------------------------------------- *)
(* In-process gateway support                                       *)
(* ---------------------------------------------------------------- *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

let resolve_keeper_for_channel_result ~channel_id =
  let normalized = String.trim channel_id in
  if String.equal normalized "" then Ok None
  else
    match read_bindings_lookup_result () with
    | Error _ as error -> error
    | Ok candidates ->
      (match
         Store.find_binding_by_channel_id candidates ~channel_id:normalized
       with
       | Some binding ->
         Ok
           (Some
              { keeper_name = binding.keeper_name
              ; incoming_channel_id = normalized
              ; bound_channel_id = binding.channel_id
              ; via_parent = false
              })
       | None ->
         let parent_binding =
           Option.bind
             (parent_channel_of_thread ~channel_id:normalized)
             (fun parent_channel_id ->
                if String.equal parent_channel_id normalized
                then None
                else
                  Store.find_binding_by_channel_id candidates
                    ~channel_id:parent_channel_id)
         in
         Ok
           (Option.map
              (fun (binding : binding) ->
                 { keeper_name = binding.keeper_name
                 ; incoming_channel_id = normalized
                 ; bound_channel_id = binding.channel_id
                 ; via_parent = true
                 })
              parent_binding))

let keeper_for_channel_result ~channel_id =
  resolve_keeper_for_channel_result ~channel_id
  |> Result.map
       (Option.map (fun resolution -> resolution.keeper_name))

(* RFC-0223 P2: presence surface. Both recomputed per call — no cached
   presence state. *)

let bound_channels_result ~keeper_name =
  Store.bound_channels_result binding_store ~keeper_name
  |> Result.map_error (fun error -> Binding_store_read_failed error)

let bound_channels ~keeper_name =
  Store.bound_channels_result binding_store ~keeper_name

let connected () =
  (* The in-process gateway (RFC-0203) is the only Discord transport;
     its run loop publishes the typed connection state. *)
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

type outbound_message =
  { content : string
  ; allowed_user_mentions : string list
  }

let text_chunks ~limit content =
  let rec split acc rest =
    if String.equal rest "" then List.rev acc
    else
      let chunk, remaining = Discord_rest_client.split_at_codepoint rest ~limit in
      split (chunk :: acc) remaining
  in
  match split [] content with
  | [] -> [ "" ]
  | chunks -> chunks

let mention_messages ~limit mention_user_ids =
  let flush content ids acc =
    if ids = [] then acc
    else
      { content; allowed_user_mentions = List.rev ids } :: acc
  in
  let rec group content ids acc = function
    | [] -> List.rev (flush content ids acc)
    | id :: rest ->
      let token = Printf.sprintf "<@%s>" id in
      let candidate = if ids = [] then token else content ^ " " ^ token in
      if String.length candidate <= limit
      then group candidate (id :: ids) acc rest
      else
        group token [ id ] (flush content ids acc) rest
  in
  group "" [] [] mention_user_ids

let message_chunks_with_mentions ~limit ~content ~mention_user_ids =
  match mention_user_ids with
  | [] ->
    text_chunks ~limit content
    |> List.map (fun content -> { content; allowed_user_mentions = [] })
  | user_ids ->
    let prefix =
      user_ids |> List.map (Printf.sprintf "<@%s>") |> String.concat " "
    in
    let combined = prefix ^ "\n" ^ content in
    if String.length combined <= limit
    then [ { content = combined; allowed_user_mentions = user_ids } ]
    else
      mention_messages ~limit user_ids
      @ (text_chunks ~limit content
         |> List.map (fun content -> { content; allowed_user_mentions = [] }))

module For_testing = struct
  type nonrec outbound_message = outbound_message =
    { content : string
    ; allowed_user_mentions : string list
    }

  let message_chunks_with_mentions = message_chunks_with_mentions
end

let send_message ~channel_id ~content ?reply_to_message_id
    ?(mention_user_ids = []) () =
  match bot_token_opt () with
  | None -> Error Missing_token
  | Some token ->
    let limit = Discord_rest_client.message_content_limit in
    let messages =
      message_chunks_with_mentions ~limit ~content ~mention_user_ids
    in
    let rec send_chunks first last_id = function
      | [] ->
        (match last_id with
         | Some id -> Ok id
         | None ->
           Error
             (Rest_error
                (Discord_rest_client.Other
                   { request_id = ""
                   ; reason = "Discord message chunker produced no output"
                   ; body_bytes = 0
                   })))
      | message :: rest ->
        let ref_id = if first then reply_to_message_id else None in
        match
          Discord_rest_client.send_message
            ~token
            ~channel_id
            ~content:message.content
            ?reply_to_message_id:ref_id
            ~allowed_user_mentions:message.allowed_user_mentions
            ()
        with
        | Ok id -> send_chunks false (Some id) rest
        | Error e -> Error (Rest_error e)
    in
    send_chunks true None messages

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
