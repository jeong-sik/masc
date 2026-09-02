(** In-process runtime handlers for descriptor-backed workspace tools.

    Each producer commits to a typed execution outcome before its opaque raw
    payload reaches dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module String_set = Set.Make (String)

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  `Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ]
;;

let unexpected_tools_list_arguments args =
  match args with
  | `Assoc [] -> None
  | other ->
    let data =
      `Assoc
         [ ( "error"
           , `Assoc
               [ "kind", `String "unexpected_arguments"
               ; "received", `String (Json_util.kind_name other)
               ] )
         ]
    in
    Some
      (Keeper_tool_execution.failure_data
         ~class_:Tool_result.Policy_rejection
         ~metadata:data
         ~message:"keeper_tools_list does not accept arguments."
         data)
;;

let handle_tools_list ~capability_surface ~args () =
  match unexpected_tools_list_arguments args with
  | Some failure -> failure
  | None ->
    Keeper_tool_execution.success
      (Keeper_tool_shared_runtime.keeper_tools_list_json_for_surface
         ~capability_surface)
;;

let handle_tools_list_from_meta ~meta ~args () =
  match unexpected_tools_list_arguments args with
  | Some failure -> failure
  | None ->
    Keeper_tool_execution.success
      (Keeper_tool_shared_runtime.keeper_tools_list_json ~meta)
;;

let capability_search_failure error =
  let data =
    `Assoc [ "error", Keeper_capability_search.error_to_yojson error ]
  in
  let class_ =
    match error with
    | Keeper_capability_search.Index_unavailable _ -> Tool_result.Runtime_failure
    | Keeper_capability_search.Empty_query
    | Keeper_capability_search.Frozen_surface_required
    | Keeper_capability_search.Invalid_query _ -> Tool_result.Policy_rejection
  in
  Keeper_tool_execution.failure_data
    ~class_
    ~metadata:data
    ~message:"Keeper capability search rejected the query."
    data
;;

let capability_search_query = function
  | `Assoc fields ->
    (match List.assoc_opt "query" fields with
     | Some (`String query) -> Ok query
     | Some other ->
       Error
         (`Assoc
            [ "kind", `String "invalid_query_type"
            ; "received", `String (Json_util.kind_name other)
            ])
     | None -> Error (`Assoc [ "kind", `String "missing_query" ]))
  | other ->
    Error
      (`Assoc
         [ "kind", `String "invalid_arguments"
         ; "received", `String (Json_util.kind_name other)
         ])
;;

let invalid_capability_search_arguments error =
  let data = `Assoc [ "error", error ] in
  Keeper_tool_execution.failure_data
    ~class_:Tool_result.Policy_rejection
    ~metadata:data
    ~message:"keeper_capability_search requires a string query."
    data
;;

let handle_capability_search ~capability_surface ~args () =
  match capability_search_query args with
  | Error error -> invalid_capability_search_arguments error
  | Ok query ->
    (match
       Keeper_tool_shared_runtime.keeper_capability_search_json_for_surface
         ~capability_surface
         ~query
     with
     | Ok data -> Keeper_tool_execution.success_data data
     | Error error -> capability_search_failure error)
;;

let handle_capability_search_from_meta ~args:_ () =
  capability_search_failure Keeper_capability_search.Frozen_surface_required
;;

type external_gate_block =
  { payload : string
  ; failure_class : Tool_result.tool_failure_class
  }

type external_gate_non_allow =
  | Gate_deferred of Keeper_gate_deferred_payload.t
  | Gate_unavailable of external_gate_block

let external_gate_decision
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      ()
  =
  match
    Keeper_gate.decide
      ?cycle_grant:gate_grant
      ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
      { keeper_name = meta.name
      ; operation
      ; input
      ; sandbox_profile = None
      ; base_path = config.Workspace.base_path
      ; causal_context = Option.map (fun current -> current ()) gate_context
      ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
      ; continuation_channel
      }
  with
  | Keeper_gate.Deferred { approval_id; reason; audit_receipts } ->
    Error
      (Gate_deferred
         (Keeper_gate_deferred_payload.create
            ~operation
            ~approval_id
            ~reason
            ~audit_receipts
            ()))
  | Keeper_gate.Unavailable reason ->
    Error
      (Gate_unavailable
         { payload =
             Yojson.Safe.to_string
               (`Assoc
                  [ "error", `String "gate_unavailable"
                  ; "message"
                  , `String
                      "External effect was not executed because the Gate could not durably record its decision state. This Keeper remains active and may continue other work."
                  ; "gate_reason"
                  , `String (Keeper_gate.unavailable_reason_to_string reason)
                  ])
         ; failure_class = Tool_result.Runtime_failure
         })
  | Keeper_gate.Allow authorization ->
    Log.Keeper.info
      ~keeper_name:meta.name
      "external effect authorized operation=%s source=%s"
      operation
      (Keeper_gate.authorization_source_to_string authorization.source);
    Ok authorization
;;

let attach_gate_authorization_to_tool_result authorization result =
  Tool_result.with_metadata
    (Keeper_gate.authorization_metadata
       ?producer_metadata:(Tool_result.metadata result)
       authorization)
    result
;;

let with_external_gate_tool_result
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  =
  match
    external_gate_decision
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      ()
  with
  | Ok authorization ->
    continue () |> attach_gate_authorization_to_tool_result authorization
  | Error (Gate_deferred deferred) ->
    Keeper_gate_deferred_payload.to_tool_result
      ~tool_name:operation
      ~start_time:(Time_compat.now ())
      deferred
  | Error (Gate_unavailable blocked) ->
    tool_result_error
      ~tool_name:operation
      ~class_:blocked.failure_class
      blocked.payload
;;

let with_external_gate_tool_result_option
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  =
  match
    external_gate_decision
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      ()
  with
  | Ok authorization ->
    Option.map
      (attach_gate_authorization_to_tool_result authorization)
      (continue ())
  | Error (Gate_deferred deferred) ->
    Some
      (Keeper_gate_deferred_payload.to_tool_result
         ~tool_name:operation
         ~start_time:(Time_compat.now ())
         deferred)
  | Error (Gate_unavailable blocked) ->
    Some
      (tool_result_error
         ~tool_name:operation
         ~class_:blocked.failure_class
         blocked.payload)
;;

let with_external_gate_execution
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  =
  match
    external_gate_decision
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      ()
  with
  | Ok authorization ->
    continue () |> Keeper_tool_execution.with_gate_authorization authorization
  | Error (Gate_deferred deferred) ->
    Keeper_gate_deferred_payload.to_execution deferred
  | Error (Gate_unavailable blocked) ->
    Keeper_tool_execution.failure
      ~class_:blocked.failure_class
      ~effect_disposition:Tool_result.Proven_pre_effect
      blocked.payload
;;

let network_read_gate_operation = Keeper_gate.network_read_gate_operation

type network_read_replay =
  | Replay_web_search of Yojson.Safe.t
  | Replay_web_fetch of Yojson.Safe.t

let unique_field key fields =
  match List.filter_map (fun (name, value) -> if String.equal name key then Some value else None) fields with
  | [ value ] -> Ok value
  | [] -> Error (Printf.sprintf "approved network_read input is missing %S" key)
  | _ -> Error (Printf.sprintf "approved network_read input repeats %S" key)
;;

let reject_unknown_network_read_fields fields =
  let unknown =
    fields
    |> List.filter_map (fun (name, _) ->
      if String.equal name "capability" || String.equal name "input"
      then None
      else Some name)
    |> List.sort_uniq String.compare
  in
  match unknown with
  | [] -> Ok ()
  | names ->
    Error
      (Printf.sprintf
         "approved network_read input has unknown field(s): %s"
         (String.concat ", " names))
;;

let network_read_replay_of_gate_input = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* () = reject_unknown_network_read_fields fields in
    let* capability = unique_field "capability" fields in
    let* input = unique_field "input" fields in
    (match capability with
     | `String "web_search" -> Ok (Replay_web_search input)
     | `String "web_fetch" -> Ok (Replay_web_fetch input)
     | `String capability ->
       Error
         (Printf.sprintf
            "approved network_read capability %S is not replayable"
            capability)
     | _ -> Error "approved network_read capability must be a string")
  | _ -> Error "approved network_read input must be an object"
;;

let handle_web_search_with_outcome
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  let input = `Assoc [ "capability", `String "web_search"; "input", args ] in
  with_external_gate_execution
    ~config
    ~meta
    ?continuation_channel
    ?gate_context
    ?gate_grant
    ~operation:network_read_gate_operation
    ~input
  @@ fun () ->
  let tool_name = "masc_web_search" in
  let start_time = Time_compat.now () in
  Tool_misc_web_search.handle ~tool_name ~start_time args
  |> Tool_misc_web_enrichment.enrich_result_if_requested
       ~tool_name
       ~start_time
       args
  |> Keeper_tool_execution.of_tool_result
;;

let handle_web_fetch_with_outcome
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  let input = `Assoc [ "capability", `String "web_fetch"; "input", args ] in
  with_external_gate_execution
    ~config
    ~meta
    ?continuation_channel
    ?gate_context
    ?gate_grant
    ~operation:network_read_gate_operation
    ~input
  @@ fun () ->
  Tool_misc_web_fetch.handle
    ~tool_name:"masc_web_fetch"
    ~start_time:(Time_compat.now ())
    args
  |> Keeper_tool_execution.of_tool_result
;;

let handle_context_status ~config ~(meta : keeper_meta) ~ctx_work ~args:_ =
  Keeper_tool_memory_runtime.keeper_context_status_json ~config ~meta ~ctx_work
;;

let handle_memory_write_with_outcome
      ~config
      ~(meta : keeper_meta)
      ~args
  =
  Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
    ~config
    ~meta
    ~args
;;

let handle_memory_retract_with_outcome
      ~config
      ~(meta : keeper_meta)
      ~args
  =
  Keeper_tool_memory_runtime.keeper_memory_retract_with_outcome
    ~config
    ~meta
    ~args
;;

let handle_library_search_with_outcome ~(meta : keeper_meta) ~args =
  Keeper_tool_execution.of_tool_result
    (Tool_library.handle_search
       ~tool_name:"keeper_library_search"
       ~start_time:0.0
       Tool_library.{ agent_name = meta.name }
       args)
;;

let handle_library_read_with_outcome ~(meta : keeper_meta) ~args =
  Keeper_tool_execution.of_tool_result
    (Tool_library.handle_read
       ~tool_name:"keeper_library_read"
       ~start_time:0.0
       Tool_library.{ agent_name = meta.name }
       args)
;;

type surface_read_mode =
  | Local_lane
  | Discord_channel
  | Discord_messages
  | Discord_members
  | Discord_member

let surface_read_mode_of_args args =
  let raw_mode =
    match args with
    | `Assoc fields ->
      (match List.assoc_opt "mode" fields with
       | None -> Ok None
       | Some (`String value) -> Ok (Some value)
       | Some _ -> Error "mode must be a string")
    | _ -> Error "tool arguments must be a JSON object"
  in
  match raw_mode with
  | Error message -> Error message
  | Ok None -> Ok Local_lane
  | Ok (Some raw) ->
    (match raw with
     | "local" -> Ok Local_lane
     | "channel" -> Ok Discord_channel
     | "messages" -> Ok Discord_messages
     | "members" -> Ok Discord_members
     | "member" -> Ok Discord_member
     | other ->
       Error
         (Printf.sprintf
            "mode %S is invalid; expected local, channel, messages, members, or member"
            other))
;;

let strict_string_opt key args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None -> Ok None
     | Some (`String value) -> Ok (Some value)
     | Some _ -> Error (Printf.sprintf "%s must be a string" key))
  | _ -> Error "tool arguments must be a JSON object"
;;

let strict_int_opt key args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None -> Ok None
     | Some (`Int value) -> Ok (Some value)
     | Some _ -> Error (Printf.sprintf "%s must be an integer" key))
  | _ -> Error "tool arguments must be a JSON object"
;;

let discord_tool_error ~code message =
  Tool_args.error_response_typed ~code message
;;

let discord_rest_error error =
  discord_tool_error
    ~code:Tool_args.Internal_error
    (Format.asprintf "Discord read failed: %a" Discord_rest_client.pp_error error)
;;

let discord_bound_channel ~meta ~args =
  let requested = strict_string_opt "channel_id" args in
  match requested with
  | Error message -> Error message
  | Ok requested ->
    (match
       Channel_gate_discord_state.bound_channels_result ~keeper_name:meta.name
     with
     | Error detail ->
       Error (Channel_gate_discord_state.binding_lookup_error_to_string detail)
     | Ok bound_channels ->
       let allowed channel_id =
         List.mem channel_id bound_channels
         ||
         match Channel_gate_discord_state.parent_channel_of_thread ~channel_id with
         | Some parent -> List.mem parent bound_channels
         | None -> false
       in
       match requested with
       | Some channel_id when channel_id <> "" ->
         if allowed channel_id then Ok channel_id
         else
           Error
             (Printf.sprintf
                "channel_id %S is not bound to keeper %s"
                channel_id meta.name)
       | Some _ -> Error "channel_id must not be empty"
       | None ->
         (match bound_channels with
          | [ channel_id ] -> Ok channel_id
          | [] -> Error "this keeper has no bound Discord channel"
          | channels ->
            Error
              (Printf.sprintf
                 "channel_id is required; this keeper has %d bound Discord channels: %s"
                 (List.length channels)
                 (String.concat ", " channels))))
;;

let discord_token () =
  match Env_config_discord.bot_token_opt () with
  | Some token -> Ok token
  | None -> Error "DISCORD_BOT_TOKEN is unset or empty"
;;

let discord_snowflake ~field value =
  match Discord_rest_client.snowflake_of_string value with
  | Ok value -> Ok value
  | Error message -> Error (Printf.sprintf "%s: %s" field message)

let discord_optional_snowflake ~field = function
  | None -> Ok None
  | Some value ->
    (match discord_snowflake ~field value with
     | Ok value -> Ok (Some value)
     | Error message -> Error message)

let discord_validate_unique_fields ~context fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
      if String_set.mem key seen then
        Error (Printf.sprintf "%s contains duplicate field %S" context key)
      else loop (String_set.add key seen) rest
  in
  loop String_set.empty fields

let discord_validate_unique_object ~context = function
  | `Assoc fields -> discord_validate_unique_fields ~context fields
  | _ -> Error (Printf.sprintf "%s is not an object" context)
;;

let discord_object_field_string key = function
  | `Assoc fields ->
    (match
       discord_validate_unique_fields ~context:"Discord response object" fields
     with
     | Error message -> Error message
     | Ok () ->
       (match List.assoc_opt key fields with
        | Some (`String value) when value <> "" -> Ok value
        | Some `Null | None ->
          Error (Printf.sprintf "Discord response has no %s" key)
        | Some _ ->
          Error (Printf.sprintf "Discord response field %s is not a string" key)))
  | _ -> Error "Discord channel response is not an object"
;;

let discord_required_snowflake_field ~field key = function
  | `Assoc fields ->
    (match
       discord_validate_unique_fields ~context:"Discord response object" fields
     with
     | Error message -> Error message
     | Ok () ->
       (match List.assoc_opt key fields with
        | Some (`String value) -> discord_snowflake ~field value
        | Some _ ->
          Error (Printf.sprintf "Discord response field %s is not a string" key)
        | None -> Error (Printf.sprintf "Discord response has no %s" key)))
  | _ -> Error "Discord response item is not an object"

let discord_channel_guild_id json =
  match discord_required_snowflake_field ~field:"id" "id" json with
  | Error message -> Error ("Discord channel response: " ^ message)
  | Ok _ -> discord_object_field_string "guild_id" json

let discord_member_user_id json =
  match json with
  | `Assoc fields ->
    (match
       discord_validate_unique_fields ~context:"Discord member object" fields
     with
     | Error message -> Error message
     | Ok () ->
       (match List.assoc_opt "user" fields with
        | Some (`Assoc user_fields) ->
          (match
             discord_validate_unique_fields
               ~context:"Discord member user object" user_fields
           with
           | Error message -> Error message
           | Ok () ->
             (match List.assoc_opt "id" user_fields with
              | Some (`String value) -> discord_snowflake ~field:"user.id" value
              | Some _ -> Error "Discord member user.id is not a string"
              | None -> Error "Discord member user has no id"))
        | Some _ -> Error "Discord member user is not an object"
        | None -> Error "Discord member has no user"))
  | _ -> Error "Discord member response item is not an object"

let discord_require_items ~kind validate = function
  | `List items ->
    let rec loop index = function
      | [] -> Ok ()
      | item :: rest ->
        (match validate item with
         | Ok _ -> loop (index + 1) rest
         | Error message ->
           Error (Printf.sprintf "Discord %s item %d: %s" kind index message))
    in
    loop 0 items
  | _ -> Error (Printf.sprintf "Discord %s response is not an array" kind)

let discord_require_shape mode json =
  match mode with
  | Discord_channel ->
    (match json with
     | `Assoc _ ->
       (match discord_required_snowflake_field ~field:"id" "id" json with
        | Ok _ -> Ok ()
        | Error message -> Error ("Discord channel response: " ^ message))
     | _ -> Error "Discord channel response is not an object")
  | Discord_member ->
    (match json with
     | `Assoc _ ->
       (match discord_member_user_id json with
        | Ok _ -> Ok ()
        | Error message -> Error ("Discord member response: " ^ message))
     | _ -> Error "Discord member response is not an object")
  | Discord_messages ->
    discord_require_items ~kind:"message"
      (fun item -> discord_required_snowflake_field ~field:"id" "id" item)
      json
  | Discord_members ->
    discord_require_items ~kind:"member" discord_member_user_id json
  | Local_lane -> Ok ()
;;

let surface_read_mode_label = function
  | Local_lane -> "local"
  | Discord_channel -> "channel"
  | Discord_messages -> "messages"
  | Discord_members -> "members"
  | Discord_member -> "member"
;;

let discord_result_count (data : Yojson.Safe.t) =
  match data with
  | `List values -> Some (List.length values)
  | `Assoc _ | `Null | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _ -> None
;;

let discord_success ~mode ~resource ~(channel_id : Discord_rest_client.snowflake)
    ?guild_id
    (data : Yojson.Safe.t) =
  let fields : (string * Yojson.Safe.t) list =
    [ "mode", `String (surface_read_mode_label mode)
    ; "resource", `String resource
    ; "scope", `String "bound_channel"
    ; "channel_id", `String (Discord_rest_client.snowflake_to_string channel_id)
    ; "data", data
    ]
    @ match guild_id with
      | Some id ->
        [ "guild_id", `String (Discord_rest_client.snowflake_to_string id) ]
      | None -> []
    @ match discord_result_count data with
      | Some count -> [ "data_count", `Int count ]
      | None -> []
  in
  Yojson.Safe.to_string (Tool_args.ok_assoc fields)
;;

let handle_discord_surface_read ~meta ~args ~mode =
  match strict_string_opt "surface" args with
  | Error message -> discord_tool_error ~code:Tool_args.Validation_error message
  | Ok (Some "discord") ->
    (match discord_bound_channel ~meta ~args, discord_token () with
     | Error message, _ ->
       discord_tool_error ~code:Tool_args.Precondition_failed message
     | _, Error message -> discord_tool_error ~code:Tool_args.Auth_required message
     | Ok raw_channel_id, Ok token ->
       (match discord_snowflake ~field:"channel_id" raw_channel_id with
        | Error message ->
          discord_tool_error ~code:Tool_args.Precondition_failed message
        | Ok channel_id ->
          let clock = Eio_context.get_clock_opt () in
          let rest ?guild_id call resource =
            match call () with
            | Error error ->
              Log.Keeper.warn
                ~keeper_name:meta.name
                "discord_surface_read failed mode=%s resource=%s channel=%s: %s"
                (surface_read_mode_label mode)
                resource
                (Discord_rest_client.snowflake_to_string channel_id)
                (Format.asprintf "%a" Discord_rest_client.pp_error error);
              discord_rest_error error
            | Ok data ->
              (match discord_require_shape mode data with
               | Error message ->
                 Log.Keeper.warn
                   ~keeper_name:meta.name
                   "discord_surface_read invalid response mode=%s resource=%s channel=%s: %s"
                   (surface_read_mode_label mode)
                   resource
                   (Discord_rest_client.snowflake_to_string channel_id)
                   message;
                 discord_tool_error ~code:Tool_args.Internal_error message
               | Ok () ->
                 Log.Keeper.info
                   ~keeper_name:meta.name
                   "discord_surface_read mode=%s resource=%s channel=%s guild=%s count=%s"
                   (surface_read_mode_label mode)
                   resource
                   (Discord_rest_client.snowflake_to_string channel_id)
                   (match guild_id with
                    | Some value -> Discord_rest_client.snowflake_to_string value
                    | None -> "-")
                   (match discord_result_count data with
                    | Some count -> string_of_int count
                    | None -> "-");
                 discord_success ~mode ~resource ~channel_id ?guild_id data)
          in
          match mode with
          | Local_lane ->
            discord_tool_error ~code:Tool_args.Internal_error
              "invalid Discord read mode"
          | Discord_channel ->
            rest
              (fun () ->
                 Discord_rest_client.get_channel ?clock ~token ~channel_id ())
              "channel"
          | Discord_messages ->
            (match
               strict_int_opt "limit" args,
               strict_string_opt "discord_before" args,
               strict_string_opt "discord_after" args
             with
             | Error message, _, _
             | _, Error message, _
             | _, _, Error message ->
               discord_tool_error ~code:Tool_args.Validation_error message
             | Ok limit, Ok before_raw, Ok after_raw ->
               if Option.is_some before_raw && Option.is_some after_raw then
                 discord_tool_error
                   ~code:Tool_args.Validation_error
                   "discord_before and discord_after are mutually exclusive"
               else
                 (match
                    discord_optional_snowflake ~field:"discord_before" before_raw,
                    discord_optional_snowflake ~field:"discord_after" after_raw
                  with
                  | Error message, _ | _, Error message ->
                    discord_tool_error ~code:Tool_args.Validation_error message
                  | Ok before, Ok after ->
                    let limit =
                      match limit with
                      | Some value -> value
                      | None -> Keeper_surface_read.default_limit
                    in
                    if limit < 1 || limit > 100 then
                      discord_tool_error
                        ~code:Tool_args.Validation_error
                        "limit for Discord messages must be between 1 and 100"
                    else
                      rest
                        (fun () ->
                           Discord_rest_client.get_channel_messages
                             ?clock ~token ~channel_id ~limit ?before ?after ())
                        "messages"))
          | Discord_members | Discord_member ->
            (match
               Discord_rest_client.get_channel ?clock ~token ~channel_id ()
             with
             | Error error ->
               Log.Keeper.warn
                 ~keeper_name:meta.name
                 "discord_surface_read failed mode=%s resource=channel channel=%s: %s"
                 (surface_read_mode_label mode)
                 (Discord_rest_client.snowflake_to_string channel_id)
                 (Format.asprintf "%a" Discord_rest_client.pp_error error);
               discord_rest_error error
             | Ok channel ->
               (match discord_channel_guild_id channel with
                | Error message ->
                  discord_tool_error ~code:Tool_args.Not_found message
                | Ok raw_guild_id ->
                  (match discord_snowflake ~field:"guild_id" raw_guild_id with
                   | Error message ->
                     discord_tool_error ~code:Tool_args.Internal_error message
                   | Ok guild_id ->
                     match mode with
                     | Discord_members ->
                       (match
                          strict_string_opt "query" args,
                          strict_int_opt "limit" args,
                          strict_string_opt "discord_after" args
                        with
                        | Error message, _, _
                        | _, Error message, _
                        | _, _, Error message ->
                          discord_tool_error ~code:Tool_args.Validation_error message
                        | Ok query, Ok limit, Ok after_raw ->
                          let searching =
                            match query with
                            | Some value -> value <> ""
                            | None -> false
                          in
                          if searching && Option.is_some after_raw then
                            discord_tool_error
                              ~code:Tool_args.Validation_error
                              "discord_after cannot be combined with a member search query"
                          else
                            (match
                               discord_optional_snowflake
                                 ~field:"discord_after" after_raw
                             with
                             | Error message ->
                               discord_tool_error
                                 ~code:Tool_args.Validation_error message
                             | Ok after ->
                               let limit =
                                 match limit with
                                 | Some value -> value
                                 | None -> Keeper_surface_read.default_limit
                               in
                               if limit < 1 || limit > 1000 then
                                 discord_tool_error
                                   ~code:Tool_args.Validation_error
                                   "limit for Discord members must be between 1 and 1000"
                               else
                                 rest
                                   (fun () ->
                                      Discord_rest_client.get_guild_members
                                        ?clock ~token ~guild_id ?query ~limit
                                        ?after ())
                                   ~guild_id
                                   "members"))
                     | Discord_member ->
                       (match strict_string_opt "user_id" args with
                        | Error message ->
                          discord_tool_error
                            ~code:Tool_args.Validation_error message
                        | Ok None | Ok (Some "") ->
                          discord_tool_error
                            ~code:Tool_args.Validation_error
                            "user_id is required for mode='member'"
                        | Ok (Some user_id) ->
                          (match discord_snowflake ~field:"user_id" user_id with
                           | Error message ->
                             discord_tool_error
                               ~code:Tool_args.Validation_error message
                           | Ok user_id ->
                             rest
                               (fun () ->
                                  Discord_rest_client.get_guild_member
                                    ?clock ~token ~guild_id ~user_id ())
                               ~guild_id
                               "member"))
                     | Local_lane | Discord_channel | Discord_messages ->
                       discord_tool_error ~code:Tool_args.Internal_error
                         "invalid Discord read mode")))))
  | Ok _ ->
    discord_tool_error
      ~code:Tool_args.Validation_error
      "Discord live read modes require surface='discord'"
;;

let handle_surface_read ~config ~(meta : keeper_meta) ~args =
  match
    discord_validate_unique_object ~context:"keeper_surface_read arguments" args
  with
  | Error message -> discord_tool_error ~code:Tool_args.Validation_error message
  | Ok () ->
    (match surface_read_mode_of_args args with
     | Error message -> discord_tool_error ~code:Tool_args.Validation_error message
     | Ok (Discord_channel | Discord_messages | Discord_members | Discord_member as mode) ->
       handle_discord_surface_read ~meta ~args ~mode
     | Ok Local_lane ->
       let surface = Safe_ops.json_string ~default:"" "surface" args in
       let limit =
         Safe_ops.json_int ~default:Keeper_surface_read.default_limit "limit" args
       in
       let before = Safe_ops.json_float_opt "before" args in
       let page =
         Keeper_chat_store.load_page
           ~base_dir:config.Workspace.base_path
           ~keeper_name:meta.name
           ?before
           ()
       in
       let notes =
         Keeper_person_notes.notes
           ~base_dir:config.Workspace.base_path
           ~keeper_name:meta.name
       in
       Keeper_surface_read.respond ~surface ~limit
         ~has_more:page.Keeper_chat_store.has_more
         ~notes
         page.Keeper_chat_store.messages)
;;

let handle_person_note_set_with_outcome ~config ~(meta : keeper_meta) ~args =
  let reject message =
    Keeper_tool_execution.failure
      ~class_:Tool_result.Workflow_rejection
      (Yojson.Safe.to_string (`Assoc [ "error", `String message ]))
  in
  let speaker_id =
    String.trim (Safe_ops.json_string ~default:"" "speaker_id" args)
  in
  if speaker_id = "" then
    reject
      "speaker_id is required. Use the id field from the keeper_surface_read roster."
  else begin
    (* Distinguish field-absent (LLM omission) from field-present-empty:
       [json_string_opt] returns [None] when [note] is absent and [Some s] when
       it is present (including ""). An explicit "" is the deliberate tombstone
       that clears the note (RFC-0229 §3.1); an omitted [note] must be rejected,
       not silently cleared. The prior [json_string ~default:""] collapsed both
       to "", so a keeper that omitted [note] silently deleted an existing note
       (AGENT_CORE anti-pattern #2: Unknown -> Permissive Default). The structural
       dispatch-level gap (in-process dispatch skips required validation) is
       tracked in #21875. *)
    match Safe_ops.json_string_opt "note" args with
    | None ->
      reject
        "note is required. Send an empty string to clear (tombstone) an existing note."
    | Some note ->
      Keeper_person_notes.set_note
        ~base_dir:config.Workspace.base_path
        ~keeper_name:meta.name
        ~speaker_id
        ~note
        ();
      Keeper_tool_execution.success
        (Yojson.Safe.to_string
           (`Assoc
             [ "ok", `Bool true
             ; "speaker_id", `String speaker_id
             ; "cleared", `Bool (String.trim note = "")
             ]))
  end
;;

let handle_person_note_set ~config ~meta ~args =
  (handle_person_note_set_with_outcome ~config ~meta ~args).raw_output
;;

(* Slack bot token, resolved through the config boundary ({!Env_config_slack})
   so [SLACK_BOT_TOKEN] is read from one place — shared with the in-process
   gateway and Owner connector delivery — rather than a direct env lookup here. *)
let slack_token_opt = Env_config_slack.bot_token_opt

let connector_post_gate_input ~connector ~channel_id ~content ~mention_user_ids
    ?thread_ts ?blocks () =
  let thread_ts_fields =
    match thread_ts with
    | None -> []
    | Some thread_ts -> [ "thread_ts", `String thread_ts ]
  in
  let block_fields =
    match blocks with
    | None -> []
    | Some blocks -> [ "blocks", `List blocks ]
  in
  `Assoc
    ([ "connector", `String connector
     ; "channel_id", `String channel_id
     ; "content", `String content
     ; "mention_user_ids", Json_util.json_string_list mention_user_ids
     ]
     @ thread_ts_fields
     @ block_fields)
;;

let connector_post_gate_operation = Keeper_gate.connector_post_gate_operation

type connector_post_replay =
  | Replay_discord_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; content : string
      ; mention_user_ids : string list
      }
  | Replay_slack_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; thread_ts : string option
      ; content : string
      ; blocks : Yojson.Safe.t list
      ; mention_user_ids : string list
      }

let connector_post_replay_of_gate_input input =
  let required_string key fields =
    match
      List.filter_map
        (fun (name, value) ->
           if String.equal name key then Some value else None)
        fields
    with
    | [ `String value ] when not (String.equal (String.trim value) "") ->
      Ok value
    | [ `String _ ] ->
      Error (Printf.sprintf "approved connector_post %s is blank" key)
    | [ _ ] ->
      Error
        (Printf.sprintf "approved connector_post %s must be a string" key)
    | [] ->
      Error (Printf.sprintf "approved connector_post is missing %s" key)
    | _ ->
      Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  (* Absent means the field was never part of the durable request (older
     approvals predate [thread_ts]); present means it must be a usable value.
     Absence is never widened into a default coordinate. *)
  let optional_string key fields =
    match
      List.filter_map
        (fun (name, value) ->
           if String.equal name key then Some value else None)
        fields
    with
    | [] -> Ok None
    | [ `String value ] when not (String.equal (String.trim value) "") ->
      Ok (Some value)
    | [ `String _ ] ->
      Error (Printf.sprintf "approved connector_post %s is blank" key)
    | [ _ ] ->
      Error
        (Printf.sprintf "approved connector_post %s must be a string" key)
    | _ ->
      Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  let required_string_list key fields =
    match
      List.filter_map
        (fun (name, value) -> if String.equal name key then Some value else None)
        fields
    with
    | [ `List values ] ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest when String.trim value <> "" ->
          decode (String.trim value :: acc) rest
        | `String _ :: _ ->
          Error (Printf.sprintf "approved connector_post %s contains a blank id" key)
        | _ :: _ ->
          Error
            (Printf.sprintf
               "approved connector_post %s must contain only strings"
               key)
      in
      decode [] values
    | [ _ ] ->
      Error (Printf.sprintf "approved connector_post %s must be an array" key)
    | [] -> Error (Printf.sprintf "approved connector_post is missing %s" key)
    | _ -> Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  let reject_unknown ~allowed fields =
    match
      fields
      |> List.filter_map (fun (name, _) ->
        if List.mem name allowed then None else Some name)
      |> List.sort_uniq String.compare
    with
    | [] -> Ok ()
    | names ->
      Error
        (Printf.sprintf
           "approved connector_post has unknown field(s): %s"
           (String.concat ", " names))
  in
  match input with
  | `Assoc fields ->
    let open Result.Syntax in
    let* connector = required_string "connector" fields in
    let* channel_id = required_string "channel_id" fields in
    let* content = required_string "content" fields in
    (* [connector_post_gate_input] always writes the list (empty when there
       are no mentions), so an absent field is a malformed request. *)
    let* mention_user_ids = required_string_list "mention_user_ids" fields in
    let* validated_mention_user_ids =
      Keeper_surface_post.user_mentions_of_args
        ~surface:connector
        (`Assoc [ "mention_user_ids", Json_util.json_string_list mention_user_ids ])
    in
    let* mention_user_ids =
      if validated_mention_user_ids = mention_user_ids then Ok mention_user_ids
      else
        Error
          "approved connector_post mention_user_ids must be sorted and unique"
    in
    if String.equal connector Keeper_surface_post.discord_label
    then (
      let* () =
        reject_unknown
          ~allowed:[ "connector"; "channel_id"; "content"; "mention_user_ids" ]
          fields
      in
      Ok
        (Replay_discord_post
           { input; channel_id; content; mention_user_ids }))
    else if String.equal connector Keeper_surface_post.slack_label
    then (
      let* () =
        reject_unknown
          ~allowed:
            [ "connector"
            ; "channel_id"
            ; "thread_ts"
            ; "content"
            ; "blocks"
            ; "mention_user_ids"
            ]
          fields
      in
      let* thread_ts = optional_string "thread_ts" fields in
      match
        List.filter_map
          (fun (name, value) ->
             if String.equal name "blocks" then Some value else None)
          fields
      with
      | [ `List blocks ] ->
        Ok
          (Replay_slack_post
             { input; channel_id; thread_ts; content; blocks; mention_user_ids })
      | [ _ ] ->
        Error "approved connector_post blocks must be an array"
      | [] ->
        Error "approved Slack connector_post is missing blocks"
      | _ ->
        Error "approved connector_post repeats blocks")
    else
      Error
        (Printf.sprintf
           "approved connector_post connector %S is unsupported"
           connector)
  | _ -> Error "approved connector_post input must be an object"
;;

let connector_post_replay_target = function
  | Replay_discord_post { channel_id; _ } ->
    Keeper_surface_post.To_discord { channel_id }
  | Replay_slack_post { channel_id; thread_ts; blocks; _ } ->
    Keeper_surface_post.To_slack
      { channel_id; thread_ts; blocks = Some blocks }
;;

let with_connector_post_gate_execution
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
      continue
  =
  with_external_gate_execution
    ~config
    ~meta
    ?continuation_channel
    ?gate_context
    ?gate_grant
    ~operation:connector_post_gate_operation
    ~input
    continue
;;

let replay_connector_post_with_outcome
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
  =
  let succeed connector ?message_id () =
    Keeper_tool_execution.success
      (Keeper_surface_post.ok_json ~surface:connector ?message_id ())
  in
  (* [effect_disposition] decides whether the keeper may correct and retry
     inside the same provider turn ({!Keeper_runtime_failure_route}: a proven
     pre-effect rejection must never reach the terminal effect boundary), so
     each connector supplies what its transport actually proves instead of
     defaulting every failure to "outcome unknown". *)
  let fail connector ~effect_disposition detail =
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition
      (Keeper_surface_post.error_json
         (Printf.sprintf "%s send failed: %s" connector detail))
  in
  let fail_after_effect connector detail =
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_post_effect
      (Keeper_surface_post.error_json
         (Printf.sprintf "%s send applied: %s" connector detail))
  in
  function
  | Replay_discord_post { input; channel_id; content; mention_user_ids } ->
    with_connector_post_gate_execution
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
    @@ fun () ->
    (match
       Channel_gate_discord_state.send_message ~channel_id ~content
         ~mention_user_ids ()
     with
     | Error send_error ->
       (* Discord stays "outcome unknown": its refusals arrive as non-2xx and
          {!Discord_rest_client.Discord_api} carries Discord's own error code
          rather than the HTTP status, so this layer cannot tell a 4xx refusal
          from a 5xx that may have committed. Claiming pre-effect here would
          license a duplicate post. *)
       fail
         Keeper_surface_post.discord_label
         ~effect_disposition:Tool_result.Effect_outcome_unknown
         (Format.asprintf
            "%a"
            Channel_gate_discord_state.pp_send_error
            send_error)
     | Ok message_id ->
       (match
          Keeper_chat_store.append_assistant_message_result
            ~base_dir:config.Workspace.base_path
            ~keeper_name:meta.name
            ~content
            ~surface:
              (Surface_ref.Discord
                 { guild_id = None
                 ; channel_id
                   (* Recalled, not fetched: the inbound path already asked
                      and wrote the answer down. Without this the pane reads
                      [#일반] on the message that arrived and an id on our own
                      reply to it -- the same room, named twice over. *)
                 ; channel_name =
                     Connector_names.recall
                       ~base_dir:config.Workspace.base_path
                       ~connector:Channel_gate_discord_state.channel
                       ~scope:Connector_names.Channel ~id:channel_id
                 ; parent_channel_id = None
                 ; thread_id = None
                 })
            ()
        with
        | Error detail ->
          fail_after_effect
            Keeper_surface_post.discord_label
            ("message sent, but local chat persistence failed: " ^ detail)
        | Ok () ->
          Keeper_chat_broadcast.chat_appended
            ~keeper_name:meta.name
            ~source:Keeper_surface_post.discord_label
            ~content
            ();
          succeed Keeper_surface_post.discord_label ~message_id ()))
  | Replay_slack_post
      { input; channel_id; thread_ts; content; blocks; mention_user_ids } ->
    with_connector_post_gate_execution
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
    @@ fun () ->
    (match slack_token_opt () with
     | None ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Runtime_failure
         ~effect_disposition:Tool_result.Proven_pre_effect
         (Keeper_surface_post.error_json "SLACK_BOT_TOKEN is unset or empty")
     | Some token ->
       (match
          Keeper_chat_slack.send_message_with_blocks
            ?thread_ts
            ~token
            ~channel:channel_id
            ~content
            ~blocks
            ~mention_user_ids
            ()
        with
        | Error send_error ->
          fail
            Keeper_surface_post.slack_label
            ~effect_disposition:(Keeper_chat_slack.effect_disposition send_error)
            (Format.asprintf "%a" Keeper_chat_slack.pp_error send_error)
        | Ok () ->
          (match
             Keeper_chat_store.append_assistant_message_result
               ~base_dir:config.Workspace.base_path
               ~keeper_name:meta.name
               ~content
               ~surface:
                 (Surface_ref.Slack
                    { team_id = None
                    ; channel_id
                    ; channel_name =
                        Connector_names.recall
                          ~base_dir:config.Workspace.base_path
                          ~connector:Channel_gate_slack_state.channel
                          ~scope:Connector_names.Channel ~id:channel_id
                    ; thread_ts
                    })
               ()
           with
           | Error detail ->
             fail_after_effect
               Keeper_surface_post.slack_label
               ("message sent, but local chat persistence failed: " ^ detail)
           | Ok () ->
             Keeper_chat_broadcast.chat_appended
               ~keeper_name:meta.name
               ~source:Keeper_surface_post.slack_label
               ~content
               ();
             succeed Keeper_surface_post.slack_label ())))
;;

let handle_surface_post_with_outcome
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  let succeed target payload =
    Keeper_tool_execution.success payload
    |> Keeper_tool_execution.with_surface_post_receipt target
  in
  let fail
        ?(class_ = Tool_result.Workflow_rejection)
        ~effect_disposition
        payload
    =
    Keeper_tool_execution.failure ~class_ ~effect_disposition payload
  in
  let surface = String.trim (Safe_ops.json_string ~default:"" "surface" args) in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let continuation_channel =
    Option.map
      (fun channel ->
         match channel with
         | Keeper_continuation_channel.Discord
             { channel_id; parent_channel_id = None; thread_id = None; _ } ->
           (match
              Channel_gate_discord_state.parent_channel_of_thread ~channel_id
            with
            | Some parent_channel_id ->
              Keeper_continuation_channel.discord_thread_parent channel
                ~parent_channel_id
            | None -> channel)
         | Keeper_continuation_channel.Discord _
         | Keeper_continuation_channel.Dashboard _
         | Keeper_continuation_channel.Slack _
         | Keeper_continuation_channel.Imessage _
         | Keeper_continuation_channel.Keeper _
         | Keeper_continuation_channel.Unrouted _ -> channel)
      continuation_channel
  in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name:meta.name
  in
  let safe_content = Keeper_secret_redaction.redact_text redaction content in
  let channel_id =
    match String.trim (Safe_ops.json_string ~default:"" "channel_id" args) with
    | "" -> None
    | id -> Some id
  in
  if surface = "" then
    fail
      ~effect_disposition:Tool_result.Proven_pre_effect
      (Keeper_surface_post.error_json
         "surface is required. Good: surface='dashboard'.")
  else if String.trim content = "" then
    fail
      ~effect_disposition:Tool_result.Proven_pre_effect
      (Keeper_surface_post.error_json "content is required and must be non-empty.")
  else match Keeper_surface_post.user_mentions_of_args ~surface args with
  | Error message ->
    fail
      ~effect_disposition:Tool_result.Proven_pre_effect
      (Keeper_surface_post.error_json message)
  | Ok mention_user_ids ->
    match Keeper_surface_post.thread_ts_of_args ~surface args with
    | Error message ->
      fail
        ~effect_disposition:Tool_result.Proven_pre_effect
        (Keeper_surface_post.error_json message)
    | Ok requested_thread_ts ->
    match Keeper_surface_post.blocks_of_args ~surface args with
    | Error message ->
      fail
        ~effect_disposition:Tool_result.Proven_pre_effect
        (Keeper_surface_post.error_json message)
    | Ok requested_blocks ->
    let requested_blocks =
      Option.map
        (List.map (Keeper_secret_redaction.redact_json redaction))
        requested_blocks
    in
    match
      Channel_gate_discord_state.bound_channels_result ~keeper_name:meta.name
    with
    | Error detail ->
      fail
        ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Proven_pre_effect
        (Keeper_surface_post.error_json
           (Channel_gate_discord_state.binding_lookup_error_to_string detail))
    | Ok bound_discord_channels ->
      (match Channel_gate_slack_state.bound_channels ~keeper_name:meta.name with
       | Error detail ->
         fail
           ~class_:Tool_result.Runtime_failure
           ~effect_disposition:Tool_result.Proven_pre_effect
           (Keeper_surface_post.error_json
              (Channel_gate_binding_store.binding_store_error_to_string detail))
       | Ok bound_slack_channels ->
       match
         Keeper_surface_post.resolve_target ~surface ~channel_id
           ?continuation_channel
           ?requested_thread_ts
           ~bound_slack_channels ~bound_discord_channels ()
       with
      | Error message ->
        fail
          ~effect_disposition:Tool_result.Proven_pre_effect
          (Keeper_surface_post.error_json message)
      | Ok target ->
        let target = Keeper_surface_post.set_blocks target requested_blocks in
        let messages =
          Keeper_chat_store.load
            ~base_dir:config.Workspace.base_path
            ~keeper_name:meta.name
        in
        (match
           Keeper_surface_post.validate_user_mentions_against_roster
             ~target ~messages mention_user_ids
         with
         | Error message ->
           fail
             ~effect_disposition:Tool_result.Proven_pre_effect
             (Keeper_surface_post.error_json message)
         | Ok () ->
         match target with
         | Keeper_surface_post.To_dashboard ->
        (match
           Keeper_chat_store.append_assistant_message_result
             ~base_dir:config.Workspace.base_path
             ~keeper_name:meta.name
             ~content:safe_content
             ~surface:(Surface_ref.Dashboard { session_id = None })
             ()
         with
         | Error detail ->
           fail
             ~class_:Tool_result.Runtime_failure
             ~effect_disposition:Tool_result.Effect_outcome_unknown
             (Keeper_surface_post.error_json detail)
         | Ok () ->
           Keeper_chat_broadcast.chat_appended ~keeper_name:meta.name
             ~source:"dashboard"
             ~content:safe_content
             ();
           succeed
             Keeper_surface_post.To_dashboard
             (Keeper_surface_post.ok_json ~surface ()))
         | Keeper_surface_post.To_discord { channel_id } ->
      let input =
        connector_post_gate_input
          ~connector:surface
          ~channel_id
          ~content:safe_content
          ~mention_user_ids
          ()
      in
      replay_connector_post_with_outcome
        ~config
        ~meta
        ?continuation_channel
        ?gate_context
        ?gate_grant
        (Replay_discord_post
           { input; channel_id; content = safe_content; mention_user_ids })
      |> Keeper_tool_execution.with_surface_post_receipt target
         | Keeper_surface_post.To_slack { channel_id; thread_ts; blocks } ->
      let slack_blocks =
        match blocks with
        | Some blocks -> blocks
        | None ->
          Keeper_chat_slack.message_blocks_of_text ~mention_user_ids safe_content
      in
      let input =
        connector_post_gate_input
          ~connector:surface
          ~channel_id
          ~content:safe_content
          ~mention_user_ids
          ?thread_ts
          ~blocks:slack_blocks
          ()
      in
      replay_connector_post_with_outcome
        ~config
        ~meta
        ?continuation_channel
        ?gate_context
        ?gate_grant
        (Replay_slack_post
           { input
           ; channel_id
           ; thread_ts
           ; content = safe_content
           ; blocks = slack_blocks
           ; mention_user_ids
           })
      |> Keeper_tool_execution.with_surface_post_receipt target))
;;

let handle_ide_annotate ~config ~(meta : keeper_meta) ~args =
  Keeper_tool_ide_runtime.handle_ide_annotate ~config ~meta ~args
;;

let handle_ide_annotate_with_outcome ~config ~(meta : keeper_meta) ~args =
  Keeper_tool_ide_runtime.handle_ide_annotate_with_outcome ~config ~meta ~args
;;

let handle_voice_with_outcome
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~name
      ~args
      ()
  =
  let authorize_external_effect ~operation ~input ~continue =
    with_external_gate_execution
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  in
  Keeper_tool_voice_runtime.handle_voice_tool_with_outcome
    ~config
    ~meta
    ~authorize_external_effect
    ~name
    ~args
    ()
;;

(* RFC-0182 §3.1 — shared helper. Converts the [Tool_result.result option]
   returned by [Tool_*.dispatch] to the producer-owned execution outcome.
   [None] means the dispatcher does not recognise the name (the descriptor →
   dispatcher mapping is misconfigured if this fires for a tool reachable via
   [descriptors_for_internal]). *)
let dispatch_option_to_execution ?failure_effect_disposition ~name = function
  | Some result ->
    Keeper_tool_execution.of_tool_result ?failure_effect_disposition result
  | None ->
    Keeper_tool_execution.failure
      (Yojson.Safe.to_string
         (`Assoc
            [ "error"
            , `String
                (Printf.sprintf
                   "descriptor projection: cluster dispatcher did not recognise %S"
                   name)
            ]))
;;

let handle_masc_task_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  (* Task actor identity must match the claim path, which acts as
     [meta.agent_name] (keeper_tool_task_runtime.ml claim_next_r). Passing
     [meta.name] here made a keeper a stranger to its own claims:
     [same_task_actor] compares raw strings, so release/done on a task the
     same physical keeper claimed was refused with
     [task_release_requires_current_owner] — whose tool_suggestion then
     prescribed masc_board_post every wake (the 2026-07-18 40× duplicate
     board post loop, executor/task-2296). Root ratchet stays open: fold both
     spellings into one typed actor id so the mismatch is unrepresentable. *)
  let ctx : Task.Tool.context =
    { config; agent_name = Keeper_tool_shared_runtime.keeper_agent_sender ~meta; sw = None }
  in
  Task.Tool.dispatch_for_keeper ~created_by:meta.name ctx ~name ~args
  |> dispatch_option_to_execution ~name
;;

let handle_masc_plan_with_outcome ~(config : Workspace.config) ~name ~args =
  let ctx : Tool_plan.context = { config } in
  Tool_plan.dispatch ctx ~name ~args |> dispatch_option_to_execution ~name
;;

let handle_masc_run_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_run.context = { config; agent_name = Some meta.name } in
  Tool_run.dispatch ctx ~name ~args |> dispatch_option_to_execution ~name
;;

let handle_masc_agent_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent.context = { config; agent_name = meta.name } in
  Tool_agent.dispatch ctx ~name ~args |> dispatch_option_to_execution ~name
;;

(* RFC-0182 §3.1 — masc_workspace_ cluster. Tool_workspace lies LATE in module
   order (depends on Keeper_runtime which depends on much of the keeper
   layer). Keeper_tool_in_process_runtime is EARLY (transitively imported
   by Keeper_tool_dispatch_runtime). A direct static import here closes a cycle.

   Resolution: dispatch through [Workspace_dispatch_ref.dispatch]. A late
   bootstrap module ([Mcp_server_eio_execute]) registers
   [Tool_workspace.dispatch] into the ref. Until registered the ref returns
   [None], surfacing a clear projection error rather than silently
   succeeding with stale state. *)
let handle_masc_workspace_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let dispatched =
    !Workspace_dispatch_ref.dispatch ~config ~agent_name:meta.name ~name ~args
  in
  dispatch_option_to_execution ~name dispatched
;;

(* RFC-0182 §3.1 — masc_misc cluster. Active after Turn_mode_codec
   extraction (2026-05-27) broke the Tool_agent_timeline → Keeper_*
   back edge that previously cycled Config → ... →
   Keeper_tool_in_process_runtime. *)
let handle_masc_misc_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_misc.context =
    { config
    ; agent_name = meta.name
    ; help_schemas = Keeper_tool_descriptor.model_visible_schemas ()
    }
  in
  Tool_misc.dispatch ctx ~name ~args
  |> dispatch_option_to_execution ~name
;;

let handle_masc_control_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_control.context = { config; agent_name = meta.name } in
  Tool_control.dispatch ctx ~name ~args |> dispatch_option_to_execution ~name
;;

let handle_masc_agent_timeline_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_agent_timeline.context = { config; agent_name = meta.name } in
  Tool_agent_timeline.dispatch
    ~load_chat:(fun ~agent_name ->
      Keeper_chat_timeline_source.lines_for_self
        ~base_dir:config.base_path ~caller_keeper_name:meta.name ~agent_name)
    ctx ~name ~args
  |> dispatch_option_to_execution ~name
;;

(* The registry and the switch are bound together on the turn's fiber, so a
   call that finds one finds the other. Outside a turn there is nowhere for a
   process to live that the caller could reach again, and saying that beats
   creating a registry no later call can find. *)
let handle_keeper_code_query_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  Keeper_tool_code_query.dispatch ~config ~meta ~name ~args
  |> dispatch_option_to_execution ~name
;;

(* A failed webmcp call cannot prove the page's tool did not run — the bridge
   may die after executeTool started — so call failures carry
   [Effect_outcome_unknown]; the list tool never executes anything. *)
let handle_keeper_webmcp_with_outcome ~name ~args =
  let failure_effect_disposition =
    if String.equal name Keeper_tool_webmcp.call_tool_name
    then Some Tool_result.Effect_outcome_unknown
    else None
  in
  Keeper_tool_webmcp.dispatch ~name ~args
  |> dispatch_option_to_execution ?failure_effect_disposition ~name
;;

(* RFC spawn-a-process-that-outlives-the-call §3.1: a backgrounded command
   "crosses the same gate as any other: path scope, redirect policy, and the
   sandbox target all apply before a process exists".

   It did not, and #32212 closed that by refusing every start. Refusing is not
   where this ends: a command that takes minutes has to run without holding
   the turn, or the keeper stops answering while it waits -- #31364 is that
   failure. Execute is the blocking shape; spawn is how the same command runs
   beside the turn. Removing it left no way to do the thing at all.

   So spawn goes through the container instead of around it. The argv comes
   from [Keeper_turn_sandbox_runtime.exec_argv], the same construction
   [run_exec_with_status_split] blocks on, and lands in the same container as
   the same uid under the same rewritten paths. What changes is that the argv
   is spawned rather than awaited.

   [Remote_ssh] still refuses. The shim speaks a length-prefixed frame
   protocol over one connection, so there is no argv to hand a spawner, and
   reaching past the shim would reach past the path jail with it. *)
let spawn_outside_boundary ~name ~(profile : sandbox_profile) ~detail =
  let profile_name =
    Keeper_types_profile_sandbox.sandbox_profile_to_string profile
  in
  Keeper_tool_execution.failure
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    (Yojson.Safe.to_string
       (`Assoc
           [ "error", `String detail
           ; "tool", `String name
           ; "sandbox_profile", `String profile_name
           ]))
;;

let spawn_sandbox_argv ~turn_sandbox_factory ~cwd ~command_argv =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | Keeper_sandbox_factory.No_factory ->
    Error "spawn needs a turn sandbox and this turn has no factory"
  | Keeper_sandbox_factory.Remote_ssh_profile ->
    Error
      "spawn does not cross the remote_ssh boundary: the exec shim speaks a \
       framed protocol over one connection, so there is no argv to background. \
       Run the command with Execute."
  (* Same boundary, other transport: a microvm guest owns its tree and is
     reached through the shim over [container exec] (RFC-0400). *)
  | Keeper_sandbox_factory.Runtime { guest_profile = Micro_vm_guest; _ } ->
    Error
      "spawn does not cross the microvm boundary: the guest's tree lives on \
       its work volume and the exec shim speaks a framed protocol over one \
       connection, so there is no argv to background. Run the command with \
       Execute."
  | Keeper_sandbox_factory.Runtime { runtime; guest_profile = Docker_guest; _ } ->
    Keeper_turn_sandbox_runtime.exec_argv
      ~validate_cached_container:false
      runtime
      ~cwd
      ~command_argv

let handle_keeper_spawn_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~turn_sandbox_factory
      ~name
      ~args
  =
  match Spawn_turn_registry.get_opt (), Eio_context.get_switch_opt () with
  | Some registry, Some sw ->
    let definition = Tool_schemas_spawn.find_definition name in
    let failure_effect_disposition =
      match definition with
      | Some { action = Tool_schemas_spawn.Start; _ } ->
        Tool_result.Effect_outcome_unknown
      | Some
          { action =
              ( Tool_schemas_spawn.Read
              | Tool_schemas_spawn.Wait
              | Tool_schemas_spawn.Stop )
          ; _
          } ->
        Tool_result.Proven_pre_effect
      | None -> Tool_result.Effect_outcome_unknown
    in
    (* Only [Start] creates a process, so only [Start] is gated. [Read],
       [Wait] and [Stop] address handles that already exist and cross nothing;
       refusing them too would hide handles a caller still has to reap. *)
    (match definition with
     | Some { action = Tool_schemas_spawn.Start; _ } ->
       (* The host cwd the container argv is built against: what the caller
          named, else the keeper's own playground root. [exec_argv] maps it to
          the container path, so the spawned process starts where an Execute
          for the same directory would. *)
       let host_cwd =
         match Json_util.get_string args "cwd" with
         | Some value when String.trim value <> "" -> String.trim value
         | Some _ | None ->
           (* From the profile already in [meta], not
              [host_root_abs_of_agent]: that one resolves the profile by
              reading the keeper TOML and raises when there is none, which
              turns an omitted cwd into an uncaught exception. The path is the
              same either way. *)
           Filename.concat
             config.Workspace.base_path
             (Keeper_sandbox.host_root_rel_of_profile
                meta.sandbox_profile
                meta.name)
       in
       (match Json_util.get_array args "argv" with
        | None ->
          Keeper_tool_execution.failure
            ~class_:Tool_result.Policy_rejection
            ~effect_disposition:Tool_result.Proven_pre_effect
            (Yojson.Safe.to_string
               (`Assoc [ "error", `String "argv is required"; "tool", `String name ]))
        | Some (`List entries) ->
          let command_argv =
            List.filter_map
              (function `String value -> Some value | _ -> None)
              entries
          in
          if List.length command_argv <> List.length entries || command_argv = []
          then
            Keeper_tool_execution.failure
              ~class_:Tool_result.Policy_rejection
              ~effect_disposition:Tool_result.Proven_pre_effect
              (Yojson.Safe.to_string
                 (`Assoc
                     [ ( "error"
                       , `String "argv must be a non-empty array of strings" )
                     ; "tool", `String name
                     ]))
          else (
            match
              spawn_sandbox_argv ~turn_sandbox_factory ~cwd:host_cwd ~command_argv
            with
            | Error detail ->
              spawn_outside_boundary ~name ~profile:meta.sandbox_profile ~detail
            | Ok sandbox_argv ->
              (* [cwd] is dropped: [exec_argv] already put it on the container
                 command as -w, and a host path handed to the spawner would
                 name a directory the process never sees. *)
              let args =
                match args with
                | `Assoc fields ->
                  `Assoc
                    (("argv", `List (List.map (fun a -> `String a) sandbox_argv))
                     :: List.filter
                          (fun (k, _) ->
                             not (String.equal k "argv" || String.equal k "cwd"))
                          fields)
                | other -> other
              in
              Tool_spawn.dispatch { Tool_spawn.registry; sw } ~name ~args
              |> dispatch_option_to_execution ~failure_effect_disposition ~name)
        | Some _ ->
          Keeper_tool_execution.failure
            ~class_:Tool_result.Policy_rejection
            ~effect_disposition:Tool_result.Proven_pre_effect
            (Yojson.Safe.to_string
               (`Assoc
                   [ "error", `String "argv must be an array"
                   ; "tool", `String name
                   ])))
     | Some
         { action =
             ( Tool_schemas_spawn.Read
             | Tool_schemas_spawn.Wait
             | Tool_schemas_spawn.Stop )
         ; _
         }
     | None ->
       Tool_spawn.dispatch { Tool_spawn.registry; sw } ~name ~args
       |> dispatch_option_to_execution ~failure_effect_disposition ~name)
  | (Some _ | None), (Some _ | None) ->
    Keeper_tool_execution.failure
      (Yojson.Safe.to_string
         (`Assoc
             [ "error", `String "spawn is only available inside a keeper turn"
             ; "tool", `String name
             ]))
;;

let handle_masc_schedule_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ~name
      ~args
      ()
  =
  let ctx : Tool_schedule.context =
    { config
    ; agent_name = meta.name
    ; stamp_keeper_wake_result_delivery =
        (fun ~payload ->
           Schedule_payload_projection.set_keeper_wake_result_delivery
             ~payload
             ~channel:continuation_channel)
    ; admit_keeper_wake_creation = Keeper_schedule_creation_admission.run
    }
  in
  Tool_schedule.dispatch ctx ~name ~args |> dispatch_option_to_execution ~name
;;

(* RFC-0252 — masc_fusion out-of-band panel+judge deliberation.  The
   gate -> fiber fork -> orchestrator logic lives in [Fusion_tool.handle];
   this handler only gathers the keeper context and loads the [fusion] policy
   from runtime.toml. The common async lifecycle owns the canonical run id.

   Switch: fusion forks a background fiber that MUST outlive this keeper turn
   (out-of-band, ~7x latency).  So it forks on the server ROOT switch
   ([Eio_context.get_root_switch_opt], documented for exactly this case —
   "work that must survive a single keeper turn"), NOT the turn-scoped
   [ctx.sw], which would cancel the deliberation when the turn ends.  Net is
   the server net capability (not turn-scoped) from the same context.  When
   either is unavailable we return an explicit error JSON rather than
   silently dropping the request (CLAUDE.md Silent-Failure avoidance). *)
let handle_masc_fusion_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta)
      ?continuation_channel ~args () =
  match Eio_context.get_root_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net ->
    (match Fusion_config_loader.load ~base_path:config.Workspace.base_path with
     | Error msg ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Runtime_failure
         (Yojson.Safe.to_string
            (`Assoc [ "ok", `Bool false; "error", `String msg ]))
     | Ok policy ->
       let now_unix = Time_compat.now () in
       Fusion_tool.handle_result
         ~sw
         ~net
         ~base_dir:config.Workspace.base_path
         ~keeper:meta.name
         ~now_unix
         ~policy
         ?continuation_channel
         ~args
         ()
       |> Keeper_tool_execution.of_tool_result)
  | _ ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      (Yojson.Safe.to_string
         (`Assoc
            [ "ok", `Bool false
            ; ( "error"
              , `String "fusion requires the server root switch + net (unavailable)" )
            ]))
;;

(* RFC-0266 §7 Phase 3 — masc_fusion_status: read-only view of the caller's
   fusion runs (in-progress + recently completed). [fusion_status_json] is the
   pure projection over any registry instance, so tests exercise it on an
   isolated [Fusion_run_registry.create ()]; [handle_masc_fusion_status] binds
   the process-wide [global] the fusion tool/sink write to and scopes by the
   calling keeper. *)
let fusion_status_json ~(registry : Fusion_run_registry.t) ~keeper ~run_id : string =
  (* Per-run serialization (field set + status vocabulary) is owned by
     Fusion_run_registry.run_to_yojson — the single serializer shared with the
     Phase 4 dashboard HTTP route and the fusion_run_status SSE event, so the
     shape never drifts between the tool and the dashboard. This function only
     adds the tool envelope + per-keeper scoping. *)
  let run_to_yojson = Fusion_run_registry.run_to_yojson in
  let belongs_to_keeper (r : Fusion_run_registry.run) =
    String.equal r.keeper keeper
  in
  let not_found () =
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool true
         ; "found", `Bool false
         ; "run_id", `String run_id
         ; "status", `String "not_found"
         ])
  in
  if String.equal run_id ""
  then begin
    let runs =
      Fusion_run_registry.list_runs registry |> List.filter belongs_to_keeper
    in
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool true
         ; "count", `Int (List.length runs)
         ; "runs", `List (List.map run_to_yojson runs)
         ])
  end
  else (
    match Fusion_run_registry.get registry ~run_id with
    | Some run when belongs_to_keeper run ->
      Yojson.Safe.to_string
        (`Assoc [ "ok", `Bool true; "found", `Bool true; "run", run_to_yojson run ])
    | Some _ | None -> not_found ())
;;

let handle_masc_fusion_status ~(meta : keeper_meta) ~args () =
  let run_id = Safe_ops.json_string ~default:"" "run_id" args |> String.trim in
  fusion_status_json ~registry:(Fusion_run_registry.global ()) ~keeper:meta.name ~run_id
;;

(* RFC-keeper-vision-delegation-tool §2.6 — analyze_image. Thin delegate to the
   vision sub-call shell in [Keeper_vision_tool], which threads the Eio net/clock
   it receives (the read-only sub-call needs net like masc_fusion needs it). *)
let handle_analyze_image_with_outcome ?sw ?clock ?net ~(meta : keeper_meta) ~args () =
  Keeper_vision_tool.handle_with_outcome ?sw ?clock ?net ~meta ~args ()
;;

let handle_masc_local_runtime_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~name
      ~args
      ()
  =
  let authorize_external_effect ~operation ~input ~continue =
    with_external_gate_tool_result
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  in
  Tool_local_runtime.dispatch
    { Tool_local_runtime_core.config
    ; agent_name = meta.name
    ; authorize_external_effect = Some authorize_external_effect
    }
    ~name
    ~args
  |> dispatch_option_to_execution ~name
;;

(* RFC-0182 §3.1 — masc_keeper cluster.  [Keeper_tool_surface] lives in lib/
   (late) but exposes keeper workspace tools.  A direct import here
   closes a cycle, so we dispatch through [Keeper_dispatch_ref], forwarding
   the Eio resources supplied by the Keeper turn.

   TEL-OK: descriptor projection — telemetry lives in the underlying
   [Keeper_tool_surface] / [Keeper_tool_surface_ops] / [Keeper_status_detail] handlers
   that the registered ref delegates to. *)
let handle_masc_keeper_with_outcome
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~name
      ~args
      ()
  =
  let authorize_external_effect ~operation ~input ~continue =
    with_external_gate_tool_result_option
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~operation
      ~input
      continue
  in
  !Keeper_dispatch_ref.dispatch
      ~config
      ~agent_name:meta.name
      ~publication_recovery_provider
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ~authorize_external_effect
      ~name
      ~args
      ()
  |> dispatch_option_to_execution ~name
;;

let handle_masc_keeper
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~config
      ~meta
      ~name
      ~args
      ()
  =
  (handle_masc_keeper_with_outcome
     ~publication_recovery_provider
     ?sw
     ?clock
     ?proc_mgr
     ?net
     ?mcp_session_id
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~config
     ~meta
     ~name
     ~args
     ()).raw_output
;;
