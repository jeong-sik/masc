open Operator_pending_confirm
open Result.Syntax

include Operator_digest_types
(* Operator_digest_session removed — team session cleanup *)
open Operator_digest_guidance

(* Retained from Operator_digest_session — used for room-level attention health *)
let health_from_attention_items (items : attention_item list) =
  if
    List.exists
      (fun (item : attention_item) -> item.severity = Sev_bad)
      items
  then "bad"
  else if items <> [] then "warn"
  else "ok"

let normalize_team_health = function
  | "healthy" -> "ok"
  | "degraded" -> "warn"
  | "critical" -> "bad"
  | other -> other

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
                    target_type = "root";
                    target_id = None;
                    actor = None;
                    evidence =
                      `Assoc
                        [
                          ("log_seq", `Int entry.seq);
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

let build_room_attention_items config =
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
          target_type = "root";
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

let canonical_keeper_attention_reason = function
  | Some "timeout_budget_exhausted" -> None
  | reason -> reason

let keeper_attention_kind reason =
  match canonical_keeper_attention_reason reason with
  | Some reason -> "keeper_" ^ reason
  | None -> "keeper_attention"

let keeper_attention_severity ~reason ~runtime_blocker_class =
  let reason = canonical_keeper_attention_reason reason in
  match reason, runtime_blocker_class with
  | Some "runtime_blocked", _
  | Some "provider_timeout", _
  | Some "continue_gate_required", _ -> Sev_bad
  | _, Some _ -> Sev_bad
  | _ -> Sev_warn

let keeper_attention_summary ~(meta : Keeper_types.keeper_meta) ~reason
    ~runtime_blocker_summary =
  let reason = canonical_keeper_attention_reason reason in
  match reason, runtime_blocker_summary with
  | Some reason, Some summary ->
      Printf.sprintf "%s needs operator attention: %s (%s)" meta.name reason summary
  | Some reason, None ->
      Printf.sprintf "%s needs operator attention: %s" meta.name reason
  | None, Some summary ->
      Printf.sprintf "%s needs operator attention (%s)" meta.name summary
  | None, None -> Printf.sprintf "%s needs operator attention" meta.name

let keeper_attention_projection config (meta : Keeper_types.keeper_meta) =
  let attention_fields = Keeper_status_bridge.attention_fields_json config meta in
  if not (assoc_bool_field ~default:false "needs_attention" attention_fields)
  then None
  else
    let blocker_fields = Keeper_status_bridge.runtime_blocker_fields_json config meta in
    let reason = assoc_string_field "attention_reason" attention_fields in
    let next_human_action =
      assoc_string_field "next_human_action" attention_fields
    in
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
          ("agent_name", `String meta.agent_name);
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
        target_type = "keeper";
        target_id = Some meta.name;
        actor = Some meta.agent_name;
        evidence;
      }
    in
    let action_reason =
      match next_human_action with
      | Some action -> Printf.sprintf "Inspect keeper attention: %s" action
      | None -> "Inspect keeper attention"
    in
    let recommended_action =
      {
        action_type = "keeper_probe";
        target_type = "keeper";
        target_id = Some meta.name;
        severity;
        reason = action_reason;
        suggested_payload =
          `Assoc
            [
              ("source", `String "operator_digest");
              ("keeper", `String meta.name);
              ("reason", string_option_to_json reason);
              ("next_human_action", string_option_to_json next_human_action);
            ];
      }
    in
    Some (attention_item, recommended_action)

let keeper_attention_projection_items config =
  Keeper_types.keeper_names config
  |> List.filter_map (fun name ->
    match Keeper_types.read_meta config name with
    | Ok (Some meta) -> keeper_attention_projection config meta
    | Ok None | Error _ -> None)

let room_recommendations _config =
  dedup_recommendations []

let room_state_json config =
  if not (Coord.is_initialized config) then
    `Assoc
      [
        ("project", `String (Filename.basename config.base_path));
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool false);
        ("pause_reason", `Null);
      ]
  else
    let state = Coord.read_state config in
    `Assoc
      [
        ("project", `String state.project);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool state.paused);
        ("pause_reason", string_option_to_json state.pause_reason);
      ]

let digest_json ?actor ?target_type ?target_id:_target_id ?include_workers:_include_workers
    (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Coord.is_initialized config) then
    let recent_reviews = Operator_review_state.recent_review_decisions_json ~limit:12 config in
    Ok
      (`Assoc
        [
          ("trace_id", `String (trace_id "opsd"));
          ("target_type", `String "root");
          ("target_id", `Null);
          ("health", `String "ok");
          ("judgment_owner", `String "fallback_read_model");
          ("authoritative_judgment_available", `Bool false);
          ("judgment", `Null);
          ("operator_judge_runtime", operator_judge_runtime_json config);
          ("attention_items", `List []);
          ("attention_summary", summary_of_attention_items []);
          ("pending_confirm_summary", pending_confirm_summary_json_of_scope (pending_confirm_scope_of_entries ?actor []));
          ("recommended_actions", `List []);
          ("recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_guidance_layer", `String "fallback");
          ("active_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_recommended_actions", `List []);
          ("active_recommendation_source", `String "fallback");
          ("active_recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("fallback_recommended_actions", `List []);
          ("recent_reviews", recent_reviews);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let room_state_json = room_state_json config in
    match target_type with
    | "root" ->
        let confirm_scope = pending_confirm_scope ?actor config in
        let keeper_attention, keeper_recommendations =
          keeper_attention_projection_items config |> List.split
        in
        let attention_items =
          build_room_attention_items config
          @ keeper_attention
          |> List.sort compare_attention
        in
        let recommended_actions =
          dedup_recommendations
            (room_recommendations config @ keeper_recommendations)
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let active_guidance =
          active_guidance_fields ~config ~actor:actor_name ~target_type:"root"
            ~target_id:None ~fallback_recommendations:recommended_actions
            ~fallback_summary:fallback_recommendation_summary
        in
        let recent_reviews =
          Operator_review_state.recent_review_decisions_json ~limit:12 config
        in
        Ok
          (`Assoc
            ([
              ("trace_id", `String (trace_id "opsd"));
              ("target_type", `String "root");
              ("target_id", `Null);
              ("health", `String (health_from_attention_items attention_items));
              ("operator_judge_runtime", operator_judge_runtime_json config);
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ("pending_confirm_summary", pending_confirm_summary_json_of_scope confirm_scope);
              ( "recommended_actions",
                `List
                  (List.map (recommended_action_to_yojson ~actor:actor_name)
                     recommended_actions) );
              ("recommendation_summary", fallback_recommendation_summary);
              ("root", room_state_json);
            ]
            @ [ ("recent_reviews", recent_reviews) ]
            @ active_guidance))
    | _ -> Error "unsupported target_type"
