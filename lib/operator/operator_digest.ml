open Operator_pending_confirm
open Result.Syntax

include Operator_digest_types
open Operator_digest_guidance

(* Retained from Operator_digest_session — used for workspace-level attention health *)
(* Read off the severities, not off the length. The old shape asked only
   whether any row was [Sev_bad] and called every other non-empty list "warn",
   which had two consequences: a [Sev_critical] row reported as amber, and a
   purely informational row -- a Keeper holding messages it has not answered
   yet -- turned the whole workspace amber. On the live runtime the second one
   held health at "warning" for eleven days over three Discord asides. *)
let health_from_attention_items (items : attention_item list) =
  let has severity =
    List.exists (fun (item : attention_item) -> item.severity = severity) items
  in
  if has Sev_critical || has Sev_bad then "bad"
  else if has Sev_warn then "warn"
  else "ok"

let tool_host_attention_window_sec = 900.0

let recent_tool_host_failures ~now () =
  let rec dedup seen acc = function
    | [] -> List.rev acc
    | (entry : Log.Ring.entry) :: rest ->
        let fresh =
          match Masc_domain.parse_iso8601_opt entry.ts with
          | Some ts -> now -. ts <= tool_host_attention_window_sec
          | None -> false
        in
        if not fresh then
          dedup seen acc rest
        else
          match Failure_envelope.find_in_json entry.details with
          | None -> dedup seen acc rest
          | Some envelope ->
              let fingerprint =
                String.concat "|"
                  [
                    envelope.cause_code;
                    Option.value ~default:"" envelope.entity_id;
                    envelope.summary;
                  ]
              in
              if List.mem fingerprint seen then
                dedup seen acc rest
              else
                let item =
                  {
                    kind = envelope.cause_code;
                    severity =
                      operator_severity_of_failure_envelope envelope.severity;
                    summary = envelope.summary;
                    target_type = Operator_action_constants.workspace_target_type;
                    target_id = None;
                    actor = None;
                    evidence =
                      `Assoc
                        [
                          ("log_ts", `String entry.ts);
                          ( "failure_envelope",
                            Failure_envelope.to_yojson envelope );
                        ];
                  }
                in
                dedup (fingerprint :: seen) (item :: acc) rest
  in
  Log.Ring.recent ~limit:12 ~module_filter:Failure_envelope.tool_host_log_module_name ()
  |> dedup [] []

let build_workspace_attention_items config =
  let pending_confirms = read_pending_confirms config in
  let pending_items =
    if pending_confirms = [] then []
    else
      [
        {
          kind = "pending_confirm_waiting";
          severity = Sev_warn;
          summary =
            Printf.sprintf "%d pending confirmation(s) are waiting for operator input"
              (List.length pending_confirms);
          target_type = Operator_action_constants.workspace_target_type;
          target_id = None;
          actor = None;
          evidence = `Assoc [ ("count", `Int (List.length pending_confirms)) ];
        };
      ]
  in
  List.sort compare_attention
    (recent_tool_host_failures ~now:(Time_compat.now ()) ()
    @ pending_items)

let assoc_bool_field ~default key fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> value
  | _ -> default

let assoc_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | _ -> None

let keeper_attention_kind reason =
  match reason with
  | Some reason -> "keeper_" ^ reason
  | None -> "keeper_attention"

let keeper_attention_severity ~reason ~runtime_blocker_class =
  match reason, runtime_blocker_class with
  | Some "runtime_blocked", _
  | Some "provider_timeout", _ -> Sev_bad
  | _, Some _ -> Sev_bad
  | _ -> Sev_warn

let keeper_attention_summary ~(meta : Keeper_meta_contract.keeper_meta) ~reason
    ~runtime_blocker_summary =
  match reason, runtime_blocker_summary with
  | Some reason, Some summary ->
      Printf.sprintf "%s needs operator attention: %s (%s)" meta.name reason summary
  | Some reason, None ->
      Printf.sprintf "%s needs operator attention: %s" meta.name reason
  | None, Some summary ->
      Printf.sprintf "%s needs operator attention (%s)" meta.name summary
  | None, None -> Printf.sprintf "%s needs operator attention" meta.name

(* Waiting connector messages are read off the event queue, not off the
   attention log. The queue is what makes a Keeper judge a message: a turn
   consumes the stimulus and settles it, and nothing else does. The attention
   log records that the message arrived, which is a different fact -- and when
   the queue dropped its pending stimuli on a snapshot it could not decode,
   the two disagreed for eleven days while this row insisted the work was
   still coming.

   One row per Keeper rather than one per message. The operator decision here
   is whether a Keeper is falling behind, not what any single message said;
   the message itself is in that Keeper's chat, with its author and surface. *)
let connector_attention_pending_selections ~base_path ~keeper_name =
  let snapshot =
    Keeper_event_queue_persistence.load_selections_with_errors ~base_path
      ~keeper_name
  in
  snapshot.Keeper_event_queue_persistence.pending
  |> List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
    match selection.Keeper_event_queue_state.source.payload with
    | Keeper_event_queue.Connector_attention _ -> true
    | _ -> false)

let connector_attention_evidence ~keeper_name selections =
  let event_ids =
    selections
    |> List.filter_map
         (fun (selection : Keeper_event_queue_state.pending_selection) ->
            match selection.Keeper_event_queue_state.source.payload with
            | Keeper_event_queue.Connector_attention { event_id; _ } ->
              Some (`String event_id)
            | _ -> None)
  in
  let oldest =
    List.fold_left
      (fun oldest (selection : Keeper_event_queue_state.pending_selection) ->
         Float.min oldest selection.Keeper_event_queue_state.source.arrived_at)
      Float.max_float selections
  in
  `Assoc
    [ ("source", `String "keeper_event_queue");
      ("keeper_name", `String keeper_name);
      ("pending_count", `Int (List.length selections));
      ("oldest_arrived_at", `Float oldest);
      ("event_ids", `List event_ids)
    ]

let connector_attention_projection ~base_path ~keeper_name =
  match connector_attention_pending_selections ~base_path ~keeper_name with
  | [] -> None
  | _ :: _ as selections ->
    let count = List.length selections in
    Some
      { kind = "keeper_connector_attention_pending";
        (* Not a warning. A Keeper holding messages it has not answered yet is
           the runtime working, and a health reading that turns amber on it
           spends the operator's attention on nothing. It earns a row so the
           queue is visible; it does not earn an alarm. *)
        severity = Sev_info;
        summary =
          (if count = 1 then
             Printf.sprintf "%s has 1 external message waiting" keeper_name
           else
             Printf.sprintf "%s has %d external messages waiting" keeper_name
               count);
        target_type = Operator_action_constants.keeper_target_type;
        target_id = Some keeper_name;
        actor = Some keeper_name;
        evidence = connector_attention_evidence ~keeper_name selections
      }

let keeper_attention_projection config (meta : Keeper_meta_contract.keeper_meta) =
  let attention_fields = Keeper_status_bridge.attention_fields_json config meta in
  if not (assoc_bool_field ~default:false "needs_attention" attention_fields)
  then None
  else
    let blocker_fields = Keeper_status_bridge.runtime_blocker_fields_json config meta in
    let reason = assoc_string_field "attention_reason" attention_fields in
    let runtime_blocker_class =
      assoc_string_field "runtime_blocker_class" blocker_fields
    in
    let runtime_blocker_summary =
      assoc_string_field "runtime_blocker_summary" blocker_fields
    in
    let severity = keeper_attention_severity ~reason ~runtime_blocker_class in
    let evidence =
      `Assoc
        [
          ("source", `String "keeper_status_bridge");
          ("keeper_name", `String meta.name);
          ("paused", `Bool meta.paused);
          ("attention", `Assoc attention_fields);
          ("runtime_blocker", `Assoc blocker_fields);
        ]
    in
    let attention_item =
      {
        kind = keeper_attention_kind reason;
        severity;
        summary =
          keeper_attention_summary ~meta ~reason ~runtime_blocker_summary;
        target_type = Operator_action_constants.keeper_target_type;
        target_id = Some meta.name;
        actor = Some meta.name;
        evidence;
      }
    in
    Some attention_item

let keeper_attention_projection_items config =
  let keeper_names = Keeper_meta_store.keeper_names config in
  let status_attention =
    keeper_names
    |> List.filter_map (fun name ->
      match Keeper_meta_store.read_meta config name with
      | Ok (Some meta) -> keeper_attention_projection config meta
      | Ok None | Error _ -> None)
  in
  let connector_attention =
    keeper_names
    |> List.filter_map (fun keeper_name ->
      connector_attention_projection ~base_path:config.base_path ~keeper_name)
  in
  status_attention @ connector_attention

let workspace_state_json config =
  if not (Workspace.is_initialized config) then
    `Assoc
      [
        ("project", `String (Filename.basename config.base_path));
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool false);
        ("pause_reason", `Null);
      ]
  else
    let state = Workspace.read_state config in
    `Assoc
      [
        ("project", `String state.project);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool state.paused);
        ("pause_reason", Json_util.string_opt_to_json state.pause_reason);
      ]

let digest_json ?actor ?target_type ?target_id:_target_id ?include_workers:_include_workers
    (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Workspace.is_initialized config) then
    Ok
      (`Assoc
        [
          ("trace_id", `String (trace_id "opsd"));
          ( "target_type"
          , `String Operator_action_constants.workspace_target_type );
          ("target_id", `Null);
          ("health", `String "ok");
          ("judgment_owner", `String "fallback_read_model");
          ("authoritative_judgment_available", `Bool false);
          ("judgment", `Null);
          ("attention_items", `List []);
          ("attention_summary", summary_of_attention_items []);
          ("pending_confirm_summary", pending_confirm_summary_json_of_scope (pending_confirm_scope_of_entries ?actor []));
          ("recommended_actions", `List []);
          ("recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_guidance_layer", `String "fallback");
          ("active_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_recommended_actions", `List []);
          ("active_recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let workspace_state_json = workspace_state_json config in
    match Operator_action_constants.target_type_of_string target_type with
    | Some Operator_action_constants.Workspace ->
        let confirm_scope = pending_confirm_scope ?actor config in
        let keeper_attention =
          keeper_attention_projection_items config
        in
        let attention_items =
          build_workspace_attention_items config
          @ keeper_attention
          |> List.sort compare_attention
        in
        let fallback_observation_summary =
          summary_of_attention_items attention_items
        in
        let empty_recommendation_summary =
          summary_of_recommendations ~actor:actor_name []
        in
        let active_guidance =
          active_guidance
            ~config
            ~target_type:Operator_action_constants.workspace_target_type
            ~target_id:None
            ~fallback_observation_summary
            ~empty_recommendation_summary
        in
        Ok
          (`Assoc
            ([
              ("trace_id", `String (trace_id "opsd"));
              ( "target_type"
              , `String Operator_action_constants.workspace_target_type );
              ("target_id", `Null);
              ("health", `String (health_from_attention_items attention_items));
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ("pending_confirm_summary", pending_confirm_summary_json_of_scope confirm_scope);
              ("recommended_actions", `List active_guidance.recommended_actions);
              ("recommendation_summary", active_guidance.recommendation_summary);
              ("workspace", workspace_state_json);
            ]
            @ active_guidance.fields))
    | Some Operator_action_constants.Keeper
    | Some Operator_action_constants.Goal
    | None -> Error "unsupported target_type"
