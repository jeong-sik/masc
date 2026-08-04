(** In-process runtime handlers for descriptor-backed workspace tools.

    Each producer commits to a typed execution outcome before its opaque raw
    payload reaches dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  Yojson.Safe.to_string
    (`Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ])
;;

let handle_tools_list ~(meta : keeper_meta) ~args:_ =
  Keeper_tool_shared_runtime.keeper_tools_list_json ~meta
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
      ; base_path = config.Workspace.base_path
      ; causal_context = Option.map (fun current -> current ()) gate_context
      ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
      ; goal_ids = meta.active_goal_ids
      ; continuation_channel
      }
  with
  | Keeper_gate.Deferred { approval_id; reason } ->
    Error
      (Gate_deferred
         (Keeper_gate_deferred_payload.create
            ~operation
            ~approval_id
            ~reason
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
    Ok ()
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
  | Ok () -> continue ()
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
  | Ok () -> continue ()
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
  | Ok () -> continue ()
  | Error (Gate_deferred deferred) ->
    Keeper_gate_deferred_payload.to_execution deferred
  | Error (Gate_unavailable blocked) ->
    Keeper_tool_execution.failure
      ~class_:blocked.failure_class
      ~effect_disposition:Tool_result.Proven_pre_effect
      blocked.payload
;;

let network_read_gate_operation = "network_read"

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

let handle_memory_search ~config ~(meta : keeper_meta) ~ctx_work ~args =
  Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta ~ctx_work ~args
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

let handle_surface_read ~config ~(meta : keeper_meta) ~args =
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
    page.Keeper_chat_store.messages
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
       (OAS anti-pattern #2: Unknown -> Permissive Default). The structural
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
   gateway and the chat-queue consumer — rather than a direct env lookup here. *)
let slack_token_opt = Env_config_slack.bot_token_opt

let connector_post_gate_input ~connector ~channel_id ~content ?blocks () =
  let block_fields =
    match blocks with
    | None -> []
    | Some blocks -> [ "blocks", `List blocks ]
  in
  `Assoc
    ([ "connector", `String connector
     ; "channel_id", `String channel_id
     ; "content", `String content
     ]
     @ block_fields)
;;

let connector_post_gate_operation = "connector_post"

type connector_post_replay =
  | Replay_discord_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; content : string
      }
  | Replay_slack_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; content : string
      ; blocks : Yojson.Safe.t list
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
    if String.equal connector Keeper_surface_post.discord_label
    then (
      let* () =
        reject_unknown
          ~allowed:[ "connector"; "channel_id"; "content" ]
          fields
      in
      Ok (Replay_discord_post { input; channel_id; content }))
    else if String.equal connector Keeper_surface_post.slack_label
    then (
      let* () =
        reject_unknown
          ~allowed:[ "connector"; "channel_id"; "content"; "blocks" ]
          fields
      in
      match
        List.filter_map
          (fun (name, value) ->
             if String.equal name "blocks" then Some value else None)
          fields
      with
      | [ `List blocks ] ->
        Ok (Replay_slack_post { input; channel_id; content; blocks })
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
  let fail connector detail =
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Effect_outcome_unknown
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
  | Replay_discord_post { input; channel_id; content } ->
    with_connector_post_gate_execution
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
    @@ fun () ->
    (match Channel_gate_discord_state.send_message ~channel_id ~content () with
     | Error send_error ->
       fail
         Keeper_surface_post.discord_label
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
  | Replay_slack_post { input; channel_id; content; blocks } ->
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
            ~token
            ~channel:channel_id
            ~content
            ~blocks
            ()
        with
        | Error send_error ->
          fail
            Keeper_surface_post.slack_label
            (Format.asprintf "%a" Keeper_chat_slack.pp_error send_error)
        | Ok () ->
          (match
             Keeper_chat_store.append_assistant_message_result
               ~base_dir:config.Workspace.base_path
               ~keeper_name:meta.name
               ~content
               ~surface:
                 (Surface_ref.Slack
                    { team_id = None; channel_id; thread_ts = None })
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
  let succeed payload = Keeper_tool_execution.success payload in
  let fail
        ?(class_ = Tool_result.Workflow_rejection)
        ~effect_disposition
        payload
    =
    Keeper_tool_execution.failure ~class_ ~effect_disposition payload
  in
  let surface = String.trim (Safe_ops.json_string ~default:"" "surface" args) in
  let content = Safe_ops.json_string ~default:"" "content" args in
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
  else
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
           ~bound_slack_channels ~bound_discord_channels ()
       with
      | Error message ->
        fail
          ~effect_disposition:Tool_result.Proven_pre_effect
          (Keeper_surface_post.error_json message)
      | Ok Keeper_surface_post.To_dashboard ->
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
           succeed (Keeper_surface_post.ok_json ~surface ()))
    | Ok (Keeper_surface_post.To_discord { channel_id }) ->
      let input =
        connector_post_gate_input
          ~connector:surface
          ~channel_id
          ~content:safe_content
          ()
      in
      replay_connector_post_with_outcome
        ~config
        ~meta
        ?continuation_channel
        ?gate_context
        ?gate_grant
        (Replay_discord_post { input; channel_id; content = safe_content })
    | Ok (Keeper_surface_post.To_slack { channel_id; blocks = _ }) ->
      let slack_blocks =
        Keeper_chat_slack.content_blocks_of_text safe_content
      in
      let input =
        connector_post_gate_input
          ~connector:surface
          ~channel_id
          ~content:safe_content
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
           ; content = safe_content
           ; blocks = slack_blocks
           }))
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

let handle_task ~config ~(meta : keeper_meta) ~name ~args =
  Keeper_tool_task_runtime.handle_keeper_task_tool ~config ~meta ~name ~args
;;

(* RFC-0182 §3.1 — shared helper. Converts the [Tool_result.result option]
   returned by [Tool_*.dispatch] to the producer-owned execution outcome.
   [None] means the dispatcher does not recognise the name (the descriptor →
   dispatcher mapping is misconfigured if this fires for a tool reachable via
   [descriptors_for_internal]). *)
let dispatch_option_to_execution ~name = function
  | Some result -> Keeper_tool_execution.of_tool_result result
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
  let ctx : Tool_misc.context = { config; agent_name = meta.name } in
  Tool_misc.dispatch_for_keeper ctx ~name ~args
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

let handle_masc_schedule_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~name ~args =
  let ctx : Tool_schedule.context =
    { config
    ; agent_name = meta.name
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
    ; agent_name = meta.agent_name
    ; authorize_external_effect = Some authorize_external_effect
    }
    ~name
    ~args
  |> dispatch_option_to_execution ~name
;;

let handle_masc_local_runtime
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~name
      ~args
      ()
  =
  (handle_masc_local_runtime_with_outcome
     ~config
     ~meta
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~name
     ~args
     ()).raw_output
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
      ~agent_name:meta.agent_name
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
