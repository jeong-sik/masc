open Operator_pending_confirm
open Result.Syntax

include Operator_digest_types
open Operator_digest_guidance

(* Used for workspace-level attention health *)
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
let tool_host_attention_limit = 12

let is_tool_host_entry (entry : Log.Ring.entry) =
  String.equal (String.lowercase_ascii entry.module_name)
    (String.lowercase_ascii Failure_envelope.tool_host_log_module_name)

let recent_tool_host_entries () =
  Log.Ring.recent ~limit:tool_host_attention_limit
    ~module_filter:Failure_envelope.tool_host_log_module_name ()

let tool_host_ring_change_affects_attention (change : Log.Ring.entry_change) =
  if is_tool_host_entry change.entry then true else
    match change.overwritten with
    | Some previous when is_tool_host_entry previous ->
        (* A profile log produced by this reader can overwrite a very old
           ToolHost row. If twelve newer rows still own the module window,
           that overwrite cannot change the selected projection or feed back
           into another read. This is an in-memory scan, never writer I/O. *)
        let retained = recent_tool_host_entries () in
        List.length retained < tool_host_attention_limit
        || List.exists (fun (entry : Log.Ring.entry) -> entry.seq < previous.seq) retained
    | Some _ | None -> false

let earlier_deadline left right = match left, right with
  | None, deadline | deadline, None -> deadline
  | Some left, Some right -> Some (Float.min left right)

let tool_host_attention_observation ~now entries =
  let rec dedup seen acc deadline = function
    | [] -> List.rev acc, deadline
    | (entry : Log.Ring.entry) :: rest ->
        match Masc_domain.parse_iso8601_opt entry.ts with
        | Some ts when now -. ts <= tool_host_attention_window_sec
            && is_tool_host_entry entry ->
          (match Failure_envelope.find_in_json entry.details with
          | None -> dedup seen acc deadline rest
          | Some envelope ->
              let fingerprint =
                String.concat "|"
                  [
                    Failure_envelope.tool_host_cause_code envelope.cause;
                    Option.value ~default:"" envelope.entity_id;
                    envelope.summary;
                  ]
              in
              if List.mem fingerprint seen then
                dedup seen acc deadline rest
              else
                let item =
                  {
                    kind = Failure_envelope.tool_host_cause_code envelope.cause;
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
                let expires = Float.next_after (ts +. tool_host_attention_window_sec) infinity in
                let next = if Float.is_finite expires then Some expires else None in
                dedup (fingerprint :: seen) (item :: acc) (earlier_deadline deadline next) rest)
        | Some _ | None -> dedup seen acc deadline rest
  in
  dedup [] [] None entries

let recent_tool_host_failure_observation ~now () =
  recent_tool_host_entries ()
  |> tool_host_attention_observation ~now

let build_workspace_attention_observation ~now config =
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
  let host_items, deadline = recent_tool_host_failure_observation ~now () in
  List.sort compare_attention (host_items @ pending_items), deadline

let build_workspace_attention_items config =
  fst (build_workspace_attention_observation ~now:(Time_compat.now ()) config)

(* [Paused_on_blocker] and [Paused] share the wire reason, so both are
   [keeper_paused]; the row's [next_human_action] tells them apart. *)
let keeper_attention_kind reason =
  "keeper_" ^ Keeper_attention_reason.to_wire reason

(* Which Keeper and why. Every item in this projection needs operator
   attention, and every surface that draws one titles its list for that, so
   the row carries only what differs between rows: the Keeper's name, the
   attention reason after a colon, and the runtime blocker summary in
   parentheses when there is one.

   The parenthetical is this row's own preview, not the blocker summary the
   source now carries whole: a digest row is one line among many, while the
   full cause -- which the failure path can write as a few hundred bytes of
   JSON -- stays one evidence field below ([evidence.runtime_blocker]). The
   edge that needs brevity cuts here; no other reader of the summary loses
   the rest. *)
let keeper_attention_summary ~name ~reason ~runtime_blocker_summary =
  let reason = Keeper_attention_reason.to_wire reason in
  match runtime_blocker_summary with
  | Some summary ->
    Printf.sprintf "%s: %s (%s)" name reason
      (Keeper_types_profile.short_preview ~max_len:160 summary)
  | None -> Printf.sprintf "%s: %s" name reason

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
  let completeness = List.fold_left (fun outcome (error : Keeper_event_queue_persistence.snapshot_read_error) ->
    Dashboard_projection_read.combine_completeness outcome
      (Partial (Printf.sprintf "Keeper %s queue: %s" keeper_name error.message)))
      Dashboard_projection_read.Complete snapshot.read_errors in
  let selections = snapshot.Keeper_event_queue_persistence.pending
  |> List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
    match selection.Keeper_event_queue_state.source.payload with
    | Keeper_event_queue.Connector_attention _ -> true
    | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
    | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
    | Keeper_event_queue.Schedule_due _ | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
    | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
    | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
    | Keeper_event_queue.Task_outcome _ -> false) in
  selections, completeness

let connector_attention_evidence ~keeper_name selections =
  let event_ids =
    selections
    |> List.filter_map
         (fun (selection : Keeper_event_queue_state.pending_selection) ->
            match selection.Keeper_event_queue_state.source.payload with
            | Keeper_event_queue.Connector_attention { event_id; _ } ->
              Some (`String event_id)
            | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
            | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
            | Keeper_event_queue.Schedule_due _ | Keeper_event_queue.Hitl_resolved _
            | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
            | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
            | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
            | Keeper_event_queue.Task_outcome _ -> None)
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
  let selections, completeness = connector_attention_pending_selections ~base_path ~keeper_name in
  let attention = match selections with
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
      } in
  attention, completeness

let keeper_attention_projection config (meta : Keeper_meta_contract.keeper_meta) =
  let runtime_blocker = Keeper_status_bridge.runtime_blocker_surface_opt config meta in
  let approval_queue = Keeper_status_bridge.read_approval_queue_attention config meta in
  let completeness = match approval_queue with
    | Keeper_status_bridge.Approval_queue_ready _ -> Dashboard_projection_read.Complete
    | Approval_queue_unavailable error -> Partial (Keeper_approval_queue_result.storage_error_to_string error) in
  let attention =
    Keeper_status_bridge.attention_of_surface config meta runtime_blocker approval_queue
  in
  let item = match attention with
  | None -> None
  | Some reason ->
    let blocker_fields =
      Keeper_status_bridge.runtime_blocker_fields_json_of_surface runtime_blocker
    in
    let runtime_blocker_summary =
      Option.map
        (fun (blocker : Keeper_status_bridge.runtime_blocker_surface) ->
           String.trim (Lazy.force blocker.summary))
        runtime_blocker
    in
    (* A runtime blocker is the bad case. The reason "runtime_blocked" comes
       only with one, so the blocker alone decides. *)
    let severity = if Option.is_some runtime_blocker then Sev_bad else Sev_warn in
    let evidence =
      `Assoc
        [
          ("source", `String "keeper_status_bridge");
          ("keeper_name", `String meta.name);
          ("paused", `Bool meta.paused);
          ( "attention",
            `Assoc
              (Keeper_status_bridge.attention_fields_json_of meta approval_queue attention)
          );
          ("runtime_blocker", `Assoc blocker_fields);
        ]
    in
    let attention_item =
      {
        kind = keeper_attention_kind reason;
        severity;
        summary =
          keeper_attention_summary ~name:meta.name ~reason
            ~runtime_blocker_summary;
        target_type = Operator_action_constants.keeper_target_type;
        target_id = Some meta.name;
        actor = Some meta.name;
        evidence;
      }
    in
    Some attention_item in
  item, completeness

let keeper_attention_observation config =
  let keeper_names, listing_completeness =
    (match Keeper_meta_store.keeper_names_result config with
     | Ok names -> names, Dashboard_projection_read.Complete
     | Error detail ->
       Log.Keeper.warn "keeper_attention_projection_items: keeper names unread: %s" detail;
       [], Partial ("Keeper roster: " ^ detail))
  in
  let status_attention, completeness =
    List.fold_left (fun (items, completeness) name ->
      match Keeper_meta_store.read_meta config name with
      | Ok (Some meta) ->
          let item, outcome = keeper_attention_projection config meta in
          (match item with None -> items | Some item -> item :: items),
          Dashboard_projection_read.combine_completeness completeness outcome
      | Ok None -> items, completeness
      | Error detail -> items, Dashboard_projection_read.combine_completeness completeness
          (Partial (Printf.sprintf "Keeper %s metadata: %s" name detail)))
      ([], listing_completeness) keeper_names
  in
  let connector_attention, completeness =
    List.fold_left (fun (items, completeness) keeper_name ->
      let item, outcome = connector_attention_projection ~base_path:config.base_path ~keeper_name in
      (match item with None -> items | Some item -> item :: items),
      Dashboard_projection_read.combine_completeness completeness outcome)
      ([], completeness) keeper_names
  in
  List.rev status_attention @ List.rev connector_attention, completeness

let workspace_state_json config =
  if not (Workspace.is_initialized config) then
    `Assoc
      [
        ("project", `String (Filename.basename config.base_path));
      ]
  else
    let state = Workspace.read_state config in
    `Assoc
      [
        ("project", `String state.project);
      ]

let observe ?actor ?target_type ?target_id:_target_id ?include_workers:_include_workers
    (ctx : 'a context) :
    (Dashboard_projection_cache.digest_observation, string) result =
  let config = ctx.config in
  let now = Time_compat.now () in
  if not (Workspace.is_initialized config) then
    Ok
      {Dashboard_projection_cache.json = `Assoc
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
        ]; next_deadline_unix = None; completeness = Dashboard_projection_read.Complete}
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let workspace_state_json = workspace_state_json config in
    match Operator_action_constants.target_type_of_string target_type with
    | Some Operator_action_constants.Workspace ->
        let confirm_scope = pending_confirm_scope ?actor config in
        let keeper_attention, completeness =
          keeper_attention_observation config
        in
        let workspace_attention, attention_deadline = build_workspace_attention_observation ~now config in
        let attention_items =
          workspace_attention
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
            ~now
            ~config
            ~target_type:Operator_action_constants.workspace_target_type
            ~target_id:None
            ~fallback_observation_summary
            ~empty_recommendation_summary
        in
        Ok
          {Dashboard_projection_cache.json = `Assoc
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
            @ active_guidance.fields);
           next_deadline_unix = earlier_deadline attention_deadline active_guidance.next_deadline_unix;
           completeness}
    | Some Operator_action_constants.Keeper
    | Some Operator_action_constants.Goal
    | None -> Error "unsupported target_type"

let digest_json ?actor ?target_type ?target_id ?include_workers ctx =
  observe ?actor ?target_type ?target_id ?include_workers ctx
  |> Result.map (fun observation -> observation.Dashboard_projection_cache.json)

module For_testing = struct
  let tool_host_attention_observation = tool_host_attention_observation
end
