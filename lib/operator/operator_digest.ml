open Operator_pending_confirm
open Result_syntax

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
          match Types.parse_iso8601_opt entry.ts with
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

let build_room_attention_items ?command_plane_summary config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> `Assoc []
  in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_items =
    [
      ( "command_issue_pressure",
        "command-plane issue pressure is elevated",
        microarch_signals |> U.member "issue_pressure" );
      ( "command_cache_contention",
        "command-plane cache contention is elevated",
        microarch_signals |> U.member "cache_contention" );
      ( "command_scheduler_efficiency",
        "command-plane scheduler efficiency is degraded",
        microarch_signals |> U.member "scheduler_efficiency" );
      ( "command_routing_confidence",
        "command-plane routing confidence is degraded",
        microarch_signals |> U.member "routing_confidence" );
      ( "command_quality_per_token",
        "command-plane quality-per-token is degraded",
        microarch_signals |> U.member "quality_per_token" );
      ( "command_verification_gate_failures",
        "command-plane verification gate failures are accumulating",
        microarch_signals |> U.member "verification_gate_failures" );
      ( "command_rework_rate",
        "command-plane rework rate is elevated",
        microarch_signals |> U.member "rework_rate" );
      ( "command_artifact_scope_drift",
        "command-plane artifact scope drift is elevated",
        microarch_signals |> U.member "artifact_scope_drift" );
      ( "command_speculative_posture",
        "command-plane speculative posture needs review",
        microarch_signals |> U.member "speculative_posture" );
    ]
    |> List.filter_map (fun (kind, summary, signal_json) ->
           match signal_json |> U.member "tone" with
           | `String ("warn" | "bad" as tone) ->
               Some
                 {
                   kind;
                   severity = operator_severity_of_string tone;
                   summary;
                   target_type = "root";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | _ -> None)
  in
  let intent_items =
    [
      ( "intent_blocked",
        "blocked intents need intervention",
        intent_summary |> U.member "blocked",
        "blocked" );
      ( "intent_handoff_ready",
        "handoff-ready intents need continuity review",
        intent_summary |> U.member "handoff_ready",
        "handoff_ready" );
    ]
    |> List.filter_map (fun (kind, summary, value_json, field_name) ->
           match value_json with
           | `Int count when count > 0 ->
               Some
                 {
                   kind;
                   severity = if count >= 3 then Sev_bad else Sev_warn;
                   summary;
                   target_type = "root";
                   target_id = None;
                   actor = None;
                   evidence =
                     `Assoc
                       [
                         (field_name, `Int count);
                       ];
                 }
           | _ -> None)
  in
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
    @ pending_items @ signal_items @ intent_items)

let room_recommendations ?command_plane_summary _config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> `Assoc []
  in
  let microarch_signals =
    command_plane_summary
    |> U.member "operations"
    |> U.member "microarch"
    |> U.member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> U.member "intents"
    |> U.member "summary"
  in
  let signal_recommendations =
    [
      ( microarch_signals |> U.member "issue_pressure",
        "broadcast",
        "command-plane issue pressure is elevated",
        "[operator] Issue pressure is elevated. Inspect blocked operations, run a dispatch tick, and checkpoint or finalize stale work." );
      ( microarch_signals |> U.member "routing_confidence",
        "broadcast",
        "command-plane routing confidence is degraded",
        "[operator] Routing confidence is low. Inspect candidate scoring and avoid risky manual rebalance until blockers clear." );
      ( microarch_signals |> U.member "quality_per_token",
        "broadcast",
        "command-plane quality-per-token is degraded",
        "[operator] Quality per token is low. Narrow the task graph, reduce weak candidates, and keep coding stages explicit before spawning more workers." );
      ( microarch_signals |> U.member "verification_gate_failures",
        "broadcast",
        "command-plane verification gate failures are accumulating",
        "[operator] Verification failures are stacking up. Stop widening the swarm, inspect implement->verify handoff quality, and patch failing gates first." );
      ( microarch_signals |> U.member "rework_rate",
        "broadcast",
        "command-plane rework rate is elevated",
        "[operator] Rework is high. Deduplicate artifact ownership and collapse parallel work that is touching the same scope." );
      ( microarch_signals |> U.member "artifact_scope_drift",
        "broadcast",
        "command-plane artifact scope drift is elevated",
        "[operator] Artifact scope drift is rising. Require explicit artifact_scope on coding stages before further routing or review." );
      ( microarch_signals |> U.member "cache_contention",
        "broadcast",
        "command-plane cache contention is elevated",
        "[operator] Cache contention is elevated. Reduce concurrent hot lanes or rebalance worker placement before scaling further." );
      ( microarch_signals |> U.member "speculative_posture",
        "broadcast",
        "command-plane speculative posture needs review",
        "[operator] Speculative posture is unstable. Review commit and abort rates before widening speculation." );
      ( intent_summary |> U.member "blocked",
        "broadcast",
        "blocked intents need intervention",
        "[operator] Some intents are blocked. Inspect intent forecast, missing dependencies, and current focus before issuing more work." );
      ( intent_summary |> U.member "handoff_ready",
        "broadcast",
        "handoff-ready intents need continuity review",
        "[operator] Handoff-ready intents are accumulating. Review continuity and either finalize or hand off explicitly." );
    ]
    |> List.filter_map
         (fun (signal_json, action_type, reason, message) ->
           match signal_json with
           | `Assoc _ -> (
               match signal_json |> U.member "tone" with
               | `String ("warn" | "bad" as tone) ->
                   Some
                     {
                       action_type;
                       target_type = "root";
                       target_id = None;
                       severity = operator_severity_of_string tone;
                       reason;
                       suggested_payload = `Assoc [ ("message", `String message) ];
                     }
               | _ -> None)
           | `Int count when count > 0 ->
               Some
                 {
                   action_type;
                   target_type = "root";
                   target_id = None;
                   severity = if count >= 3 then Sev_bad else Sev_warn;
                   reason;
                   suggested_payload = `Assoc [ ("message", `String message) ];
                 }
           | _ -> None)
  in
  dedup_recommendations signal_recommendations

(* Re-export from Operator_digest_review_types without [include] to
   avoid conflicting [module U] and leaking [open] directives. *)
type review_item = Operator_digest_review_types.review_item = {
  id : string;
  kind : string;
  target_type : string;
  target_id : string option;
  severity : operator_severity;
  urgency : string;
  summary : string;
  why_now : string;
  source : string;
  authoritative : bool;
  fingerprint : string;
  stale_sec : int option;
  confirm_required : bool;
  recommended_action : recommended_action option;
  truth_ref : Yojson.Safe.t;
  friction : Yojson.Safe.t;
  advice : Yojson.Safe.t;
}
let review_empty_advice_json = Operator_digest_review_types.review_empty_advice_json
let review_truth_ref_json = Operator_digest_review_types.review_truth_ref_json
let json_string_opt = Operator_digest_review_types.json_string_opt
let json_float_opt = Operator_digest_review_types.json_float_opt
let json_bool_opt = Operator_digest_review_types.json_bool_opt
let review_fingerprint = Operator_digest_review_types.review_fingerprint
let stale_sec_of_iso = Operator_digest_review_types.stale_sec_of_iso
let review_action_copy = Operator_digest_review_types.review_action_copy

let room_state_json config =
  if not (Room.is_initialized config) then
    `Assoc
      [
        ("project", `String (Filename.basename config.base_path));
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool false);
        ("pause_reason", `Null);
      ]
  else
    let state = Room.read_state config in
    `Assoc
      [
        ("project", `String state.project);
        ("cluster", `String (Env_config_core.cluster_name ()));
        ("paused", `Bool state.paused);
        ("pause_reason", string_option_to_json state.pause_reason);
      ]

let keeper_context_ratio (meta : Keeper_types.keeper_meta) =
  let input_tokens = meta.runtime.usage.last_input_tokens in
  if input_tokens = 0 then None
  else
    let active_model = Keeper_exec_status.active_model_of_meta meta in
    if active_model = "" then None
    else
      let max_ctx = Oas_model_resolve.max_context_of_label active_model in
      if max_ctx = 0 then None
      else Some (float_of_int input_tokens /. float_of_int max_ctx)

let lightweight_keeper_rows config =
  Keeper_types.keeper_names config
  |> List.filter_map (fun name ->
         match Keeper_types.read_meta config name with
         | Error _ | Ok None -> None
         | Ok (Some meta) ->
             let agent_json =
               Keeper_exec_status.parse_agent_status config ~agent_name:meta.agent_name
             in
             let status =
               match agent_json |> U.member "status" with
               | `String value -> value
               | _ -> "unknown"
             in
             Some
               (`Assoc
                 [
                   ("name", `String meta.name);
                   ("agent_name", `String meta.agent_name);
                   ("status", `String status);
                   ("context_ratio", option_to_json (fun value -> `Float value) (keeper_context_ratio meta));
                   ("updated_at", `String meta.updated_at);
                 ]))

(* review_fingerprint, stale_sec_of_iso, review_action_copy
   — now in Operator_digest_review_types (available via include above) *)

let urgency_rank = function
  | "now" -> 1
  | _ -> 0

let target_rank value =
  if Operator_digest_types.is_root_alias value then 3
  else match value with
  | "keeper" -> 1
  | _ -> 0

let kind_rank = function
  | "pending_confirm" -> 4
  | "session_risk" -> 3
  | "namespace_gate" -> 2
  | "keeper_pressure" -> 1
  | _ -> 0

let compare_review_item (left : review_item) (right : review_item) =
  let by_severity = Int.compare (severity_rank right.severity) (severity_rank left.severity) in
  if by_severity <> 0 then by_severity
  else
    let by_urgency = Int.compare (urgency_rank right.urgency) (urgency_rank left.urgency) in
    if by_urgency <> 0 then by_urgency
    else
      let by_kind = Int.compare (kind_rank right.kind) (kind_rank left.kind) in
      if by_kind <> 0 then by_kind
      else
        let by_confirm =
          Bool.compare right.confirm_required left.confirm_required
        in
        if by_confirm <> 0 then by_confirm
        else
          let by_stale =
            Int.compare
              (Option.value ~default:(-1) right.stale_sec)
              (Option.value ~default:(-1) left.stale_sec)
          in
          if by_stale <> 0 then by_stale
          else
            let by_target = Int.compare (target_rank right.target_type) (target_rank left.target_type) in
            if by_target <> 0 then by_target
            else String.compare left.id right.id

let review_item_to_yojson ~actor (item : review_item) =
  `Assoc
    [
      ("id", `String item.id);
      ("kind", `String item.kind);
      ("target_type", `String item.target_type);
      ("target_id", string_option_to_json item.target_id);
      ("severity", `String (operator_severity_to_string item.severity));
      ("urgency", `String item.urgency);
      ("summary", `String item.summary);
      ("why_now", `String item.why_now);
      ("source", `String item.source);
      ("authoritative", `Bool item.authoritative);
      ("fingerprint", `String item.fingerprint);
      ("stale_sec", option_to_json (fun value -> `Int value) item.stale_sec);
      ("confirm_required", `Bool item.confirm_required);
      ( "recommended_action",
        option_to_json (recommended_action_to_yojson ~actor) item.recommended_action );
      ("truth_ref", item.truth_ref);
      ("friction", item.friction);
      ("advice", item.advice);
    ]

let review_summary_json ~actor active deferred recent =
  let top_item =
    match active with
    | item :: _ -> Some item
    | [] -> None
  in
  `Assoc
    [
      ("active_count", `Int (List.length active));
      ("deferred_count", `Int (List.length deferred));
      ("recent_count", `Int recent);
      ("top_item", option_to_json (review_item_to_yojson ~actor) top_item);
    ]

(* top_attention_item and top_recommended_action removed — team session cleanup *)

let pending_confirm_review_item ~now (entry : pending_confirm) =
  let summary =
    Printf.sprintf "%s 승인 대기" (review_action_copy entry.action_type)
  in
  let why_now =
    Printf.sprintf "%s이/가 실행 전 사람 확인을 기다리고 있습니다."
      (review_action_copy entry.action_type)
  in
  let recommended_action =
    Some
      {
        action_type = entry.action_type;
        target_type = entry.target_type;
        target_id = entry.target_id;
        severity = if Operator_approval.confirm_required entry.action_type then Sev_bad else Sev_warn;
        reason = why_now;
        suggested_payload = entry.payload;
      }
  in
  {
    id = "pending_confirm:" ^ entry.token;
    kind = "pending_confirm";
    target_type = entry.target_type;
    target_id = entry.target_id;
    severity =
      if Operator_approval.confirm_required entry.action_type then Sev_bad else Sev_warn;
    urgency = "now";
    summary;
    why_now;
    source = "deterministic";
    authoritative = true;
    fingerprint = entry.token;
    stale_sec = stale_sec_of_iso ~now (Some entry.created_at);
    confirm_required = true;
    recommended_action;
    truth_ref =
      review_truth_ref_json ~target_type:entry.target_type ~target_id:entry.target_id;
    friction =
      `Assoc
        [
          ("attention_items", `List []);
          ("risk_digest", `Null);
          ("pending_confirm", pending_confirm_to_yojson entry);
        ];
    advice = review_empty_advice_json;
  }

let namespace_gate_review_item ~room_json =
  let paused = json_bool_opt room_json "paused" |> Option.value ~default:false in
  if not paused then None
  else
    let room_id =
      json_string_opt room_json "project" |> Option.value ~default:"default"
    in
    let pause_reason =
      json_string_opt room_json "pause_reason" |> Option.value ~default:"운영 점검"
    in
    let summary = "기본 namespace가 현재 일시정지 상태입니다." in
    let recommended_action =
      Some
        {
          action_type = "namespace_resume";
          target_type = "root";
          target_id = None;
          severity = Sev_warn;
          reason = pause_reason;
          suggested_payload = `Assoc [];
        }
    in
    Some
      {
        id = "namespace_gate:" ^ room_id;
        kind = "namespace_gate";
        target_type = "root";
        target_id = None;
        severity = Sev_warn;
        urgency = "soon";
        summary;
        why_now = pause_reason;
        source = "deterministic";
        authoritative = true;
        fingerprint = review_fingerprint [ room_id; "paused"; pause_reason ];
        stale_sec = None;
        confirm_required = false;
        recommended_action;
        truth_ref = review_truth_ref_json ~target_type:"root" ~target_id:None;
        friction =
          `Assoc
            [
              ("attention_items", `List []);
              ("risk_digest", `Null);
              ("pending_confirm", `Null);
              ("room", room_json);
            ];
        advice = review_empty_advice_json;
      }

(* session_review_item removed — team session cleanup *)

let keeper_review_item ~now keeper_json =
  let name = json_string_opt keeper_json "name" in
  match name with
  | None -> None
  | Some keeper_name ->
      let status =
        json_string_opt keeper_json "status"
        |> Option.value ~default:"unknown"
        |> String.lowercase_ascii
      in
      let context_ratio = json_float_opt keeper_json "context_ratio" in
      let reasons =
        [
          (if Dashboard_utils.is_keeper_offline status then Some "오프라인" else None);
          (if status = "" || status = "unknown" then Some "상태 미수집" else None);
          (match context_ratio with
          | Some value when value >= 0.8 -> Some "컨텍스트 80%+"
          | _ -> None);
          (match context_ratio with
          | None -> Some "컨텍스트 텔레메트리 없음"
          | _ -> None);
        ]
        |> List.filter_map (fun value -> value)
      in
      if reasons = [] then None
      else
        let severity =
          if List.mem "오프라인" reasons then Sev_bad else Sev_warn
        in
        let recommended_action =
          Some
            {
              action_type =
                (match severity with Sev_bad | Sev_critical -> "keeper_recover"
                | Sev_warn -> "keeper_probe");
              target_type = "keeper";
              target_id = Some keeper_name;
              severity;
              reason = String.concat " · " reasons;
              suggested_payload =
                (match severity with Sev_bad | Sev_critical ->
                  `Assoc [ ("reason", `String "operator review queue") ]
                | Sev_warn -> `Assoc []);
            }
        in
        Some
          {
            id = "keeper_pressure:" ^ keeper_name;
            kind = "keeper_pressure";
            target_type = "keeper";
            target_id = Some keeper_name;
            severity;
            urgency = (match severity with Sev_bad | Sev_critical -> "now"
              | Sev_warn -> "soon");
            summary = Printf.sprintf "키퍼 %s 점검이 필요합니다." keeper_name;
            why_now = String.concat " · " reasons;
            source = "deterministic";
            authoritative = true;
            fingerprint =
              review_fingerprint
                [
                  keeper_name;
                  status;
                  (match context_ratio with
                  | Some value -> Printf.sprintf "%.3f" value
                  | None -> "none");
                  String.concat "|" reasons;
                ];
            stale_sec =
              stale_sec_of_iso ~now (json_string_opt keeper_json "updated_at");
            confirm_required = false;
            recommended_action;
            truth_ref =
              review_truth_ref_json ~target_type:"keeper"
                ~target_id:(Some keeper_name);
            friction =
              `Assoc
                [
                  ("attention_items", `List []);
                  ("risk_digest", `Null);
                  ("pending_confirm", `Null);
                  ("keeper", keeper_json);
                ];
            advice = review_empty_advice_json;
          }

let split_review_items config items =
  List.fold_left
    (fun (active, deferred) item ->
      match
        Operator_review_state.matching_review_decision config ~item_id:item.id
          ~fingerprint:item.fingerprint
      with
      | Some decision when String.equal decision.decision "resolved" ->
          (active, deferred)
      | Some decision when String.equal decision.decision "deferred" ->
          (active, item :: deferred)
      | _ -> (item :: active, deferred))
    ([], []) items

let review_queue_json ~actor active deferred recent_json =
  let active =
    active |> List.sort compare_review_item
  in
  let deferred =
    deferred |> List.sort compare_review_item
  in
  let recent_count =
    match recent_json with
    | `List rows -> List.length rows
    | _ -> 0
  in
  [
    ("review_queue", `List (List.map (review_item_to_yojson ~actor) active));
    ("deferred_queue", `List (List.map (review_item_to_yojson ~actor) deferred));
    ("review_summary", review_summary_json ~actor active deferred recent_count);
    ("recent_reviews", recent_json);
  ]

let digest_json ?actor ?target_type ?target_id:_target_id ?include_workers:_include_workers
    ?command_plane_summary ?swarm_status (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Room.is_initialized config) then
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
          ("provenance_summary", operator_surface_contract_json);
          ("judgment", `Null);
          ("operator_judge_runtime", operator_judge_runtime_json config);
          ("command_plane", `Assoc []);
          ("swarm_status", Swarm_status.empty_json);
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
          ("review_queue", `List []);
          ("deferred_queue", `List []);
          ("review_summary", review_summary_json ~actor:"dashboard" [] [] 0);
          ("recent_reviews", recent_reviews);
          ("worker_cards", `List []);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let now = Time_compat.now () in
    let room_state_json = room_state_json config in
    let command_plane_digest_json =
      match command_plane_summary with
      | Some summary -> summary
      | None -> `Assoc []
    in
    let swarm_status_json =
      match swarm_status with
      | Some json -> json
      | None ->
          Swarm_status.build_json ~timeline_limit_override:6 config
    in
    match target_type with
    | "root" ->
        let confirm_scope = pending_confirm_scope ?actor config in
        let attention_items =
          build_room_attention_items ~command_plane_summary:command_plane_digest_json config
          |> List.sort compare_attention
        in
        let recommended_actions =
          dedup_recommendations
            (room_recommendations ~command_plane_summary:command_plane_digest_json config)
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let active_guidance =
          active_guidance_fields ~config ~actor:actor_name ~target_type:"root"
            ~target_id:None ~fallback_recommendations:recommended_actions
            ~fallback_summary:fallback_recommendation_summary
        in
        let keeper_rows = lightweight_keeper_rows config in
        let review_items =
          (confirm_scope.visible_entries
          |> List.map (pending_confirm_review_item ~now))
          @ (match namespace_gate_review_item ~room_json:room_state_json with
            | Some item -> [ item ]
            | None -> [])
          @ (keeper_rows |> List.filter_map (keeper_review_item ~now))
        in
        let active_reviews, deferred_reviews =
          split_review_items config review_items
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
              ("provenance_summary", operator_surface_contract_json);
              ("operator_judge_runtime", operator_judge_runtime_json config);
              ("command_plane", command_plane_digest_json);
              ("swarm_status", swarm_status_json);
              ("role_census", `Assoc []);
              ("runtime_pools", `Assoc []);
              ("lane_census", `Assoc []);
              ("controller_census", `Assoc []);
              ("control_domains", `Assoc []);
              ("task_profiles", `Assoc []);
              ("escalation_count", `Int 0);
              ("local_runtime", `Null);
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ("pending_confirm_summary", pending_confirm_summary_json_of_scope confirm_scope);
              ( "recommended_actions",
                `List
                  (List.map (recommended_action_to_yojson ~actor:actor_name)
                     recommended_actions) );
              ("recommendation_summary", fallback_recommendation_summary);
              ("root", room_state_json);
              ("worker_cards", `List []);
            ]
            @ review_queue_json ~actor:actor_name active_reviews deferred_reviews recent_reviews
            @ active_guidance))
    | _ -> Error "unsupported target_type"
(* Note: normalize_digest_target_type accepts "root"/"namespace"/"room" and
   returns canonical "root" — the match above only needs the canonical case. *)
