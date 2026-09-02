(** Generic file-backed Channel Gate connector state for Python sidecars. *)

module U = Yojson.Safe.Util
module Store = Channel_gate_binding_store

module type Config = sig
  val connector_id : string
  val display_name : string
  val channel : string
  val default_status_path : string
  val default_binding_store_path : string
  val default_binding_audit_path : string
  val status_path_env_names : string list
  val binding_store_path_env_names : string list
  val binding_audit_path_env_names : string list
  val stale_after_env_name : string
  val guild_id_field : Channel_gate_binding_store.guild_id_field
  val default_poll_interval_sec : float

  val extra_status_fields :
    Yojson.Safe.t option -> (string * Yojson.Safe.t) list
end

module Make (Config : Config) = struct
  type binding = Store.binding = {
    channel_id : string;
    keeper_name : string;
  }

  let connector_id = Config.connector_id
  let display_name = Config.display_name
  let channel = Config.channel

  let stale_after_sec () =
    Env_config_core.get_int ~default:30 Config.stale_after_env_name

  (* [raw_value_opt] rather than [Sys.getenv_opt]: it falls back to the
     boot-time config overrides, so a path declared in runtime.toml is seen
     the way every other MASC setting is (#21972 P2-1). *)
  let configured_write_path env_names ~default =
    env_names
    |> List.find_map (fun name ->
           Env_config_core.raw_value_opt name |> Env_config_core.trim_opt)
    |> Option.value ~default
    |> Env_config_core.resolve_against_base_path

  let status_path () =
    configured_write_path Config.status_path_env_names
      ~default:Config.default_status_path

  let binding_store_path () =
    configured_write_path Config.binding_store_path_env_names
      ~default:Config.default_binding_store_path

  let binding_store_read_path = binding_store_path

  let binding_audit_path () =
    configured_write_path Config.binding_audit_path_env_names
      ~default:Config.default_binding_audit_path

  let binding_audit_read_path = binding_audit_path

  let binding_store =
    Store.create ~binding_store_path ~binding_store_read_path
      ~binding_audit_path ~binding_audit_read_path
      ~guild_id_field:Config.guild_id_field

  let read_json_file_opt = Store.read_json_file_opt
  let read_bindings_result () = Store.read_bindings_result binding_store
  let binding_json = Store.binding_json
  let read_recent_audit ~limit = Store.read_recent_audit binding_store ~limit

  let string_member json key =
    Json_util.get_string_with_default json ~key ~default:""

  let int_member json key =
    Json_util.get_int json key |> Option.value ~default:0

  let bool_member json key =
    Json_util.get_bool json key |> Option.value ~default:false

  let bool_option_member json key = Json_util.get_bool json key

  let stale_of_updated_at updated_at =
    match Gate_time_util.parse_iso8601_opt updated_at with
    | Some ts -> Unix.gettimeofday () -. ts > float_of_int (stale_after_sec ())
    | None -> true

  (* RFC-0223 P2: presence surface. Both recomputed per call — no
     cached presence state. *)

  let bound_channels ~keeper_name =
    Store.bound_channels_result binding_store ~keeper_name

  let connected () =
    (* Same liveness reading as [status_json]: the sidecar heartbeats
       its status file; a missing or stale file means not live. *)
    match read_json_file_opt (status_path ()) with
    | None -> false
    | Some json ->
        let updated_at = string_member json "updated_at" in
        bool_member json "connected" && not (stale_of_updated_at updated_at)

  (* Every numeric field below is a display projection of what the sidecar
     last wrote, so an absent field reads as its zero rather than an error.
     That is the shape this whole record already had; [poll_interval_sec] is
     the one whose zero differs per connector, which is why it comes from the
     config instead of being written in twice. Only [available], [stale] and
     [connected] decide anything, and none of them defaults. *)
  let status_json ?(audit_limit = 10) () =
    let status_path = status_path () in
    let live_status = read_json_file_opt status_path in
    let binding_store_path = binding_store_read_path () in
    let audit_path = binding_audit_read_path () in
    let configured_bindings_result = read_bindings_result () in
    let configured_bindings, binding_store_error =
      match configured_bindings_result with
      | Ok bindings -> bindings, ""
      | Error error -> [], Store.binding_store_error_to_string error
    in
    let binding_store_read_ok = Result.is_ok configured_bindings_result in
    let recent_audit = read_recent_audit ~limit:audit_limit in
    let available = Option.is_some live_status && binding_store_read_ok in
    let updated_at =
      match live_status with
      | Some json -> string_member json "updated_at"
      | None -> ""
    in
    let stale = if not available then true else stale_of_updated_at updated_at in
    let connected =
      match live_status with
      | Some json ->
        binding_store_read_ok && bool_member json "connected" && not stale
      | None -> false
    in
    let error =
      if not binding_store_read_ok then binding_store_error
      else if available then "" else "connector status file not found"
    in
    let status_field key f default =
      match live_status with
      | Some json -> f json key
      | None -> default
    in
    `Assoc
      ([
        ("channel", `String channel);
        ("available", `Bool available);
        ("connected", `Bool connected);
        ("stale", `Bool stale);
        ("stale_after_sec", `Int (stale_after_sec ()));
        ( "status",
          `String
            (Channel_gate_connector.connector_state_label ~available ~connected
               ~stale) );
        ("error", `String error);
        ("status_path", `String status_path);
        ("binding_store_path", `String binding_store_path);
        ("binding_store_read_ok", `Bool binding_store_read_ok);
        ("binding_store_error", `String binding_store_error);
        ("audit_path", `String audit_path);
        ("updated_at", `String updated_at);
        ("last_message_at", `String (status_field "last_message_at" string_member ""));
        ( "messages_processed",
          `Int (status_field "messages_processed" int_member 0) );
        ("messages_failed", `Int (status_field "messages_failed" int_member 0));
        ( "poll_interval_sec",
          `Float
            (status_field "poll_interval_sec"
               (fun json key ->
                 (* sound-partial: allow — relocated default, see below *)
                 Json_util.get_float json key
                 |> Option.value ~default:Config.default_poll_interval_sec)
               Config.default_poll_interval_sec) );
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
        ( "binding_source",
          `String (status_field "binding_source" string_member "persisted") );
        ( "runtime_bindings_count",
          `Int
            (status_field "runtime_bindings_count" int_member
               (List.length configured_bindings)) );
        ("configured_bindings", `List (List.map binding_json configured_bindings));
        ("recent_audit", `List recent_audit);
      ]
      @ Config.extra_status_fields live_status)

  let connector_json ?(audit_limit = 10) () =
    let status = status_json ~audit_limit () in
    (* [status] already carries the connector-specific fields; copy them by
       the keys the config declares so the two views cannot drift. *)
    let extra_fields =
      Config.extra_status_fields None
      |> List.map (fun (key, _default) -> (key, U.member key status))
    in
    `Assoc
      ([
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
        ("status_path", `String (string_member status "status_path"));
        ("binding_store_path", `String (string_member status "binding_store_path"));
        ("binding_store_read_ok", status |> U.member "binding_store_read_ok");
        ("binding_store_error", status |> U.member "binding_store_error");
        ("audit_path", `String (string_member status "audit_path"));
        ("updated_at", `String (string_member status "updated_at"));
        ("last_message_at", `String (string_member status "last_message_at"));
        ("messages_processed", `Int (int_member status "messages_processed"));
        ("messages_failed", `Int (int_member status "messages_failed"));
        ("poll_interval_sec", status |> U.member "poll_interval_sec");
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
      @ extra_fields)

  let bind ~channel_id ~keeper_name ~actor_name =
    let channel_id = String.trim channel_id in
    let keeper_name = String.trim keeper_name in
    if channel_id = "" then Error "channel_id is required"
    else if keeper_name = "" then Error "keeper_name is required"
    else
      Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
        let previous_keeper =
          match
            List.find_map
              (fun (binding : binding) ->
                if String.equal binding.channel_id channel_id then
                  Some binding.keeper_name
                else None)
              original_bindings
          with
          | Some name -> name
          | None -> ""
        in
        let updated_bindings =
          ({ channel_id; keeper_name } : binding)
          :: List.filter
               (fun (binding : binding) ->
                 not (String.equal binding.channel_id channel_id))
               original_bindings
          |> List.sort (fun (a : binding) (b : binding) ->
                 String.compare a.channel_id b.channel_id)
        in
        let event = Store.{
            timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
            action = "bind";
            channel_id;
            keeper_name;
            actor_id = actor_name;
            actor_name;
            previous_keeper;
          }
        in
        Ok (updated_bindings, event, ()))
      |> Result.map_error Store.mutation_error_to_string
      |> Result.map (fun () -> status_json ())

  let unbind_internal ?expected_keeper_name ~channel_id ~actor_name () =
    let channel_id = String.trim channel_id in
    if channel_id = "" then Error "channel_id is required"
    else
      Store.mutate_bindings binding_store ~decide:(fun original_bindings ->
        match
          List.find_opt
            (fun (binding : binding) -> String.equal binding.channel_id channel_id)
            original_bindings
        with
        | None -> Error "binding not found"
        | Some (previous : binding)
          when (match expected_keeper_name with
                | Some expected ->
                  not (String.equal expected previous.keeper_name)
                | None -> false) ->
          Error "binding changed"
        | Some previous ->
          let updated_bindings =
            List.filter
              (fun (binding : binding) ->
                not (String.equal binding.channel_id channel_id))
              original_bindings
          in
          let event = Store.{
                timestamp = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ());
                action = "unbind";
                channel_id;
                keeper_name = previous.keeper_name;
                actor_id = actor_name;
                actor_name;
                previous_keeper = previous.keeper_name;
              }
          in
          Ok (updated_bindings, event, ()))
      |> Result.map_error Store.mutation_error_to_string
      |> Result.map (fun () -> status_json ())

  let unbind ~channel_id ~actor_name =
    unbind_internal ~channel_id ~actor_name ()

  let unbind_if_keeper ~channel_id ~expected_keeper_name ~actor_name =
    unbind_internal ~expected_keeper_name ~channel_id ~actor_name ()
end
