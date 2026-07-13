open Operator_pending_confirm
open Result.Syntax

include Operator_digest_types
(* Operator_digest_session removed — team session cleanup *)
open Operator_digest_guidance

(* Retained from Operator_digest_session — used for workspace-level attention health *)
let health_from_attention_items (items : attention_item list) =
  if
    List.exists
      (fun (item : attention_item) -> item.severity = Sev_bad)
      items
  then "bad"
  else if items <> [] then "warn"
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

let metadata_string key metadata =
  match List.assoc_opt key metadata with
  | Some value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | None -> None

let metadata_json metadata =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) metadata)

let external_attention_kind (item : Keeper_external_attention.item) =
  match metadata_string "kind" item.metadata with
  | Some kind -> "keeper_" ^ kind
  | None -> "keeper_external_attention"

let external_attention_severity (item : Keeper_external_attention.item) =
  match item.urgency with
  | Keeper_external_attention.System -> Sev_bad
  | Keeper_external_attention.Mention
  | Keeper_external_attention.Direct_message
  | Keeper_external_attention.Ambient -> Sev_warn

let external_attention_summary (item : Keeper_external_attention.item) =
  let preview = String.trim item.content_preview in
  if String.equal preview "" then
    Printf.sprintf "%s has external attention from %s" item.keeper_name
      item.source_label
  else
    Printf.sprintf "%s has external attention from %s: %s" item.keeper_name
      item.source_label preview

let external_attention_evidence (item : Keeper_external_attention.item) =
  let grounded_fields =
    match metadata_string "grounded_verdict" item.metadata with
    | Some value -> [ ("grounded_verdict", `String value) ]
    | None -> []
  in
  `Assoc
    ([
       ("source", `String "keeper_external_attention");
       ("event_id", `String item.event_id);
       ("dedupe_key", `String item.dedupe_key);
       ("keeper_name", `String item.keeper_name);
       ("source_label", `String item.source_label);
       ("urgency", `String (Keeper_external_attention.urgency_to_string item.urgency));
       ("content_preview", `String item.content_preview);
       ("metadata", metadata_json item.metadata);
     ]
     @ grounded_fields)

let external_attention_projection item =
  let severity = external_attention_severity item in
  let attention_item =
    {
      kind = external_attention_kind item;
      severity;
      summary = external_attention_summary item;
      target_type = Operator_action_constants.keeper_target_type;
      target_id = Some item.keeper_name;
      actor = Some item.keeper_name;
      evidence = external_attention_evidence item;
    }
  in
  let recommended_action =
    {
      action_type = "keeper_probe";
      target_type = Operator_action_constants.keeper_target_type;
      target_id = Some item.keeper_name;
      severity;
      reason = "Inspect pending external attention";
      suggested_payload =
        `Assoc
          [
            ("source", `String "operator_digest");
            ("keeper", `String item.keeper_name);
            ("event_id", `String item.event_id);
            ("conversation_id", `String item.conversation.conversation_id);
          ];
    }
  in
  (attention_item, recommended_action)

let keeper_attention_projection config (meta : Keeper_meta_contract.keeper_meta) =
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
        target_type = Operator_action_constants.keeper_target_type;
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
        target_type = Operator_action_constants.keeper_target_type;
        target_id = Some meta.name;
        severity;
        reason = action_reason;
        suggested_payload =
          `Assoc
            [
              ("source", `String "operator_digest");
              ("keeper", `String meta.name);
              ("reason", Json_util.string_opt_to_json reason);
              ("next_human_action", Json_util.string_opt_to_json next_human_action);
            ];
      }
    in
    Some (attention_item, recommended_action)

let keeper_attention_projection_items config =
  let keeper_names = Keeper_meta_store.keeper_names config in
  let status_attention =
    keeper_names
    |> List.filter_map (fun name ->
      match Keeper_meta_store.read_meta config name with
      | Ok (Some meta) -> keeper_attention_projection config meta
      | Ok None | Error _ -> None)
  in
  let external_attention =
    keeper_names
    |> List.concat_map (fun keeper_name ->
      Keeper_external_attention.pending_for_keeper ~base_path:config.base_path
        ~keeper_name ~limit:3 ()
      |> List.map external_attention_projection)
  in
  status_attention @ external_attention

let workspace_recommendations _config =
  dedup_recommendations []

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
    let recent_reviews = Operator_review_state.recent_review_decisions_json ~limit:12 config in
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
    let workspace_state_json = workspace_state_json config in
    match Operator_action_constants.target_type_of_string target_type with
    | Some Operator_action_constants.Workspace ->
        let confirm_scope = pending_confirm_scope ?actor config in
        let keeper_attention, keeper_recommendations =
          keeper_attention_projection_items config |> List.split
        in
        let attention_items =
          build_workspace_attention_items config
          @ keeper_attention
          |> List.sort compare_attention
        in
        let recommended_actions =
          dedup_recommendations
            (workspace_recommendations config @ keeper_recommendations)
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let active_guidance =
          active_guidance_fields
            ~config
            ~actor:actor_name
            ~target_type:Operator_action_constants.workspace_target_type
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
              ( "target_type"
              , `String Operator_action_constants.workspace_target_type );
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
              ("workspace", workspace_state_json);
            ]
            @ [ ("recent_reviews", recent_reviews) ]
            @ active_guidance))
    | Some Operator_action_constants.Keeper
    | Some Operator_action_constants.Goal
    | None -> Error "unsupported target_type"
