(** Keeper status bridge helpers. *)

open Keeper_types

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)



let drift_surface_json ~unknown_toml_keys =
  `Assoc
    [
      ("unknown_toml_keys", string_list_to_json unknown_toml_keys);
      ("unknown_toml_keys_count", `Int (List.length unknown_toml_keys));
    ]

let auto_execution_session_surface_json () =
  `Assoc
    [
      ("status", `String "removed");
      ("enabled", `Bool false);
    ]

let coordination_surface_json (meta : keeper_meta) =
  `Assoc
    [
      ("mention_targets", string_list_to_json meta.mention_targets);
      ("joined_room_ids", string_list_to_json meta.joined_room_ids);
    ]

let effective_declarative_cascade_name
    (defaults : keeper_profile_defaults)
    (meta : keeper_meta) =
  match defaults.cascade_name, defaults.manifest_path with
  | Some cascade_name, _ ->
      Keeper_cascade_profile.normalize_declared_name cascade_name
  | None, Some _ -> Keeper_config.default_cascade_name
  | None, None ->
      Keeper_cascade_profile.normalize_declared_name meta.cascade_name

type override_field_detail = {
  field : string;
  default_value : Yojson.Safe.t;
  live_value : Yojson.Safe.t;
}

let override_field field ~default_value ~live_value =
  { field; default_value; live_value }

let maybe_string_override field ?(normalize = fun value -> value) default live
    acc =
  let default = Option.map normalize default in
  match default with
  | Some value when value <> live ->
      override_field field ~default_value:(`String value) ~live_value:(`String live)
      :: acc
  | _ -> acc

let maybe_bool_override field default live acc =
  match default with
  | Some value when value <> live ->
      override_field field ~default_value:(`Bool value) ~live_value:(`Bool live)
      :: acc
  | _ -> acc

let maybe_string_list_override field default live acc =
  match default with
  | Some authored when authored <> live ->
      override_field field ~default_value:(string_list_to_json authored)
        ~live_value:(string_list_to_json live)
      :: acc
  | _ -> acc

let nonempty_string_list_override field default live acc =
  if default <> [] && default <> live then
    override_field field ~default_value:(string_list_to_json default)
      ~live_value:(string_list_to_json live)
    :: acc
  else acc

let maybe_string_option_override field default live acc =
  match default, live with
  | Some authored, Some active when authored <> active ->
      override_field field ~default_value:(`String authored)
        ~live_value:(`String active)
      :: acc
  | _ -> acc

let live_override_details (meta : keeper_meta)
    (defaults : keeper_profile_defaults) : override_field_detail list =
  let effective_cascade_name =
    effective_declarative_cascade_name defaults meta
  in
  []
  |> maybe_string_override "prompt.goal"
       ~normalize:normalize_goal_horizon_text defaults.goal meta.goal
  |> maybe_string_override "prompt.short_goal" defaults.short_goal meta.short_goal
  |> maybe_string_override "prompt.mid_goal" defaults.mid_goal meta.mid_goal
  |> maybe_string_override "prompt.long_goal" defaults.long_goal meta.long_goal
  |> maybe_string_override "prompt.will" defaults.will meta.will
  |> maybe_string_override "prompt.needs" defaults.needs meta.needs
  |> maybe_string_override "prompt.desires" defaults.desires meta.desires
  |> maybe_string_override "prompt.instructions" defaults.instructions
       meta.instructions
  |> nonempty_string_list_override "coordination.mention_targets"
       defaults.mention_targets meta.mention_targets
  |> maybe_string_list_override "tools.tool_denylist" defaults.tool_denylist
       meta.tool_denylist
  |> (fun acc ->
       if effective_cascade_name <> meta.cascade_name then
         override_field "model.cascade_name"
           ~default_value:(`String effective_cascade_name)
           ~live_value:(`String meta.cascade_name)
         :: acc
       else acc)
  |> maybe_bool_override "proactive.enabled" defaults.proactive_enabled
       meta.proactive.enabled
  |> List.rev

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults) :
    string list =
  live_override_details meta defaults |> List.map (fun detail -> detail.field)

let runtime_registry_entry (config : Coord_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name

let runtime_keepalive_running (config : Coord_utils.config) (meta : keeper_meta) =
  Keeper_registry.is_running ~base_path:config.base_path meta.name

let runtime_keepalive_started_at (config : Coord_utils.config)
    (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name

(* ── Structured blocker classification ──────────────────────── *)
(* Types blocker_class, cascade_exhaustion_reason, blocker_class_to_string,
   cascade_exhaustion_summary, blocker_class_continue_gate
   are defined in Keeper_types (keeper_types.ml). *)

let blocker_class_of_string (reason : string) : blocker_class option =
  let trimmed = String.trim reason in
  if trimmed = "" then None
  else if
    String_util.contains_substring_ci trimmed
      "turn outcome ambiguous after committed mutating tool call(s)"
  then
    Some
      (if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
       then Ambiguous_post_commit_timeout
       else Ambiguous_post_commit_failure)
  else if String_util.contains_substring_ci trimmed "cascade_exhausted" then
    let reason =
      if String_util.contains_substring_ci trimmed "connection refused" then
        Connection_refused
      else if
        String_util.contains_substring_ci trimmed "no providers available"
      then
        No_providers_available
      else if
        String_util.contains_substring_ci trimmed "error_max_turns"
        || String_util.contains_substring_ci trimmed
             "reached maximum number of turns"
        || String_util.contains_substring_ci trimmed "max turns exceeded"
      then
        Max_turns_exceeded
      else if String_util.contains_substring_ci trimmed "all providers failed"
      then
        All_providers_failed
      else
        Other_detail trimmed
    in
    Some (Cascade_exhausted reason)
  else if String_util.contains_substring_ci trimmed "admission queue wait timeout"
  then
    Some Admission_queue_wait_timeout
  else if
    String_util.contains_substring_ci trimmed
      "autonomous turn slot wait timeout"
  then
    Some Autonomous_slot_wait_timeout
  else if String_util.contains_substring_ci trimmed "oas budget timeout"
  then
    Some Oas_timeout_budget
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
  then
    Some Turn_timeout
  else if
    (* 2026-05-05: Completion contract violations (e.g. require_tool_use)
       were text-stamped to runtime.last_blocker but left
       runtime.last_blocker_class null because [blocker_class_of_sdk_error]
       returned None on the [Agent_sdk.Error.Agent
       (CompletionContractViolation _)] path and the fallthrough to
       [blocker_class_of_string] had no matching substring.  Variant
       [Completion_contract_violation] was already defined in
       [Keeper_types.blocker_class] — only the mapping was missing.
       Affected 4/14 keepers in production (glm-coding-plan, janitor,
       velvet-hammer, verifier) where dashboard "차단된 키퍼" card and
       Prometheus blocker-class series were silent on this failure mode. *)
    String_util.contains_substring_ci trimmed "completion contract"
  then
    Some Completion_contract_violation
  else
    None

let blocker_class_of_sdk_error (err : Agent_sdk.Error.sdk_error) : blocker_class option =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Cascade_exhausted { reason; _ }) ->
      Some (Cascade_exhausted reason)
  | Some (Oas_worker_named.Resumable_cli_session { detail; _ }) ->
      Some (Cascade_exhausted (Other_detail detail))
  | Some (Oas_worker_named.No_tool_capable_provider _) ->
      Some No_tool_capable_provider
  | Some (Oas_worker_named.Accept_rejected _) ->
      None
  | Some (Oas_worker_named.Admission_queue_timeout _) ->
      Some Admission_queue_wait_timeout
  | Some (Oas_worker_named.Admission_queue_rejected _) ->
      None
  | Some (Oas_worker_named.Oas_timeout_budget _) ->
      Some Oas_timeout_budget
  | Some (Oas_worker_named.Turn_timeout _) ->
      Some Turn_timeout
  | Some (Oas_worker_named.Ambiguous_post_commit { is_timeout; _ }) ->
      Some
        (if is_timeout then Ambiguous_post_commit_timeout
         else Ambiguous_post_commit_failure)
  | None -> (
      match err with
      | Agent_sdk.Error.Internal msg -> blocker_class_of_string msg
      | Agent_sdk.Error.Agent
          (Agent_sdk.Error.CompletionContractViolation _) ->
          (* See note on [blocker_class_of_string] above; same gap, same
             enum target.  Direct typed match preferred over text-substring
             fallback when the SDK gave us a structured error. *)
          Some Completion_contract_violation
      | _ -> None)

(* ── Runtime blocker surface ───────────────────────────────── *)

type runtime_blocker_surface = {
  blocker_class : string;
  summary : string;
  continue_gate : bool;
}

let is_timeout_budget_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Oas_timeout_budget)
  || String.equal blocker_class (blocker_class_to_string Turn_timeout)

let runtime_blocker_surface_of_typed_class ?(summary = "") (cls : blocker_class) :
    runtime_blocker_surface =
  let str = blocker_class_to_string cls in
  let continue_gate = blocker_class_continue_gate cls in
  let summary = match cls with
    | Cascade_exhausted reason ->
        if summary = "" then cascade_exhaustion_summary reason else summary
    | Oas_timeout_budget ->
        if summary = "" then
          "OAS budget timeout fired before the keeper hard timeout."
        else summary
    | No_tool_capable_provider -> (
        match
          Oas_worker_named.classify_masc_internal_error
            (Agent_sdk.Error.Internal summary)
        with
        | Some err -> (
            match Oas_worker_named.summary_of_masc_internal_error err with
            | Some structured_summary -> structured_summary
            | None -> if summary = "" then str else summary)
        | None -> if summary = "" then str else summary)
    | _ -> if summary = "" then str else summary
  in
  { blocker_class = str; summary; continue_gate }

let runtime_blocker_surface_of_legacy_string reason cls =
  match cls with
  | Cascade_exhausted _ ->
      runtime_blocker_surface_of_typed_class cls
  | _ ->
      runtime_blocker_surface_of_typed_class ~summary:reason cls

let stale_kill_class_summary (kill_class : Keeper_registry.stale_kill_class) =
  match kill_class with
  | Keeper_registry.Idle_turn { stall_seconds } ->
      Printf.sprintf
        "idle_turn: no completed turn for %.0fs; stale watchdog stopped the keeper before restart."
        stall_seconds
  | Keeper_registry.In_turn_hung { active_seconds; timeout_threshold } ->
      Printf.sprintf
        "in_turn_hung: active turn ran for %.0fs past the %.0fs timeout; stale watchdog stopped the keeper."
        active_seconds timeout_threshold
  | Keeper_registry.Noop_failure_loop { noop_count } ->
      Printf.sprintf
        "noop_failure_loop: %d consecutive turn(s) produced no tool calls; stale watchdog stopped the keeper."
        noop_count

let runtime_blocker_surface_of_failure_reason
    (reason : Keeper_registry.failure_reason) =
  match reason with
  | Keeper_registry.Heartbeat_consecutive_failures count ->
      Some
        {
          blocker_class = "heartbeat_failures";
          summary =
            Printf.sprintf
              "Heartbeat failed %d consecutive cycle(s); supervisor recovery is required."
              count;
          continue_gate = false;
        }
  | Keeper_registry.Turn_consecutive_failures count ->
      Some
        {
          blocker_class = "turn_failures";
          summary =
            Printf.sprintf
              "Keeper turn failed %d consecutive cycle(s); inspect the last runtime error before retry."
              count;
          continue_gate = false;
        }
  | Keeper_registry.Stale_turn_timeout kill_class ->
      Some
        (runtime_blocker_surface_of_typed_class
           ~summary:(stale_kill_class_summary kill_class)
           Stale_turn_timeout)
  | Keeper_registry.Stale_termination_storm { count } ->
      Some
        {
          blocker_class = "stale_termination_storm";
          summary =
            Printf.sprintf
              "Stale watchdog terminated %d keeper cycle(s) in the storm window; operator investigation is required before restart."
              count;
          continue_gate = false;
        }
  | Keeper_registry.Oas_timeout_budget_loop { count } ->
      Some
        (runtime_blocker_surface_of_typed_class
           ~summary:
             (Printf.sprintf
                "OAS budget timeout repeated %d consecutive cycle(s); keeper was auto-paused before restart loop."
                count)
           Oas_timeout_budget)
  | Keeper_registry.Stale_fleet_batch { distinct_count } ->
      Some
        (runtime_blocker_surface_of_typed_class
           ~summary:
             (Printf.sprintf
                "Stale watchdog terminated %d distinct keeper(s) inside the fleet batch window; keeper was auto-paused before restart loop."
                distinct_count)
           Stale_fleet_batch)
  | Keeper_registry.Provider_runtime_error { code; detail } ->
      Some
        {
          blocker_class = "provider_runtime_error";
          summary = Printf.sprintf "%s: %s" code detail;
          continue_gate = false;
        }
  | Keeper_registry.Tool_required_unsatisfied { code; detail } ->
      Some
        {
          blocker_class = "tool_required_unsatisfied";
          summary = Printf.sprintf "%s: %s" code detail;
          continue_gate = false;
        }
  | Keeper_registry.Ambiguous_partial_commit { kind; detail } ->
      let blocker_class =
        match kind with
        | Keeper_registry.Post_commit_timeout ->
            "ambiguous_post_commit_timeout"
        | Keeper_registry.Post_commit_failure ->
            "ambiguous_post_commit_failure"
      in
      Some
        {
          blocker_class;
          summary = detail;
          continue_gate = true;
        }
  | Keeper_registry.Fiber_unresolved ->
      Some
        (runtime_blocker_surface_of_typed_class
           ~summary:
             "Keeper fiber did not resolve a terminal outcome; supervisor cleanup is required."
           Fiber_unresolved)
  | Keeper_registry.Exception detail ->
      Some
        {
          blocker_class = "exception";
          summary = Printf.sprintf "Keeper runtime exception: %s" detail;
          continue_gate = false;
        }

let has_any_ci text needles =
  List.exists (String_util.contains_substring_ci text) needles

let first_nonempty_line label values =
  values
  |> List.map String.trim
  |> List.find_map (fun value ->
         if String.equal value "" then None
         else Some (Printf.sprintf "%s: %s" label value))

let progress_snapshot_narrative_lines
    (snapshot : Keeper_memory_policy.keeper_state_snapshot) =
  [
    (match snapshot.progress with
     | Some progress -> Some ("Progress: " ^ String.trim progress)
     | None -> None);
    (match snapshot.done_summary with
     | Some done_summary -> Some ("Done: " ^ String.trim done_summary)
     | None -> None);
    (match snapshot.next_summary with
     | Some next_summary -> Some ("Next plan: " ^ String.trim next_summary)
     | None -> None);
    first_nonempty_line "Next" snapshot.next_items;
    first_nonempty_line "Decisions" snapshot.decisions;
    first_nonempty_line "OpenQuestions" snapshot.open_questions;
    first_nonempty_line "Constraints" snapshot.constraints;
  ]
  |> List.filter_map (function
         | Some line when not (String.equal (String.trim line) "") -> Some line
         | _ -> None)

let narrative_summary line =
  String_util.utf8_safe ~max_bytes:220 ~suffix:"..." line
  |> String_util.to_string

let runtime_blocker_surface_of_progress_snapshot
    (snapshot : Keeper_memory_policy.keeper_state_snapshot) =
  let lines = progress_snapshot_narrative_lines snapshot in
  let text = String.concat "\n" lines in
  let line_with needles =
    List.find_opt (fun line -> has_any_ci line needles) lines
  in
  let surface blocker_class line =
    Some
      {
        blocker_class;
        summary = narrative_summary line;
        continue_gate = false;
      }
  in
  if lines = [] then None
  else
    match
      line_with
        [
          "sandbox egress";
          "push egress";
          "github.com push";
          "github push";
          "network egress";
          "sandbox";
        ]
    with
    | Some line
      when has_any_ci line [ "egress"; "push"; "github.com"; "network" ] ->
        surface "awaiting_sandbox_egress" line
    | _ ->
      (match line_with [ "supervisor"; "supervisor가" ] with
       | Some line when has_any_ci line [ "pause"; "paused"; "unpause"; "의도" ]
         -> surface "supervisor_paused" line
       | _ ->
         (match
            line_with
              [
                "push gate";
                "operator";
                "human";
                "approval";
                "approve";
                "decision tree";
                "4-gate";
                "4 gate";
                "unblock";
                "manual";
              ]
          with
          | Some line
            when has_any_ci
                   line
                   [
                     "waiting";
                     "await";
                     "blocked";
                     "respond";
                     "resolved";
                     "gate";
                     "decision";
                     "approval";
                     "approve";
                     "unblock";
                     "manual";
                   ] ->
              surface "awaiting_operator" line
          | _ ->
            if Keeper_synthetic_marker.contains_marker text
               && has_any_ci
                    text
                    [
                      "no visible output";
                      "last output";
                      "belief_summary";
                      "social_model";
                      "실제 막힘";
                    ]
            then
              surface "synthetic_stall"
                (line_with [ Keeper_synthetic_marker.marker_prefix ]
                 |> Option.value ~default:(List.hd lines))
            else (
              match
                line_with
                  [
                    "watching";
                    "monitor";
                    "no action";
                    "no next action";
                    "자체 action 부재";
                    "감시";
                  ]
              with
              | Some line -> surface "self_imposed_idle" line
              | None -> None)))

let runtime_blocker_surface_of_progress_narrative config
    (meta : keeper_meta) =
  let from_continuity_summary =
    match
      Keeper_memory_policy.progress_snapshot_cache_of_text meta.continuity_summary
    with
    | Some cache -> runtime_blocker_surface_of_progress_snapshot cache.snapshot
    | None -> None
  in
  match from_continuity_summary with
  | Some _ as blocker -> blocker
  | None ->
      (match Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name with
       | Some snapshot -> runtime_blocker_surface_of_progress_snapshot snapshot
       | None -> None)

let proactive_runtime_reason_is_current (meta : keeper_meta) =
  let proactive_ts = meta.runtime.proactive_rt.last_ts in
  let last_turn_ts = meta.runtime.usage.last_turn_ts in
  proactive_ts > 0.0
  && (last_turn_ts <= 0.0 || proactive_ts >= last_turn_ts)

let runtime_blocker_surface_opt (config : Coord_utils.config)
    (meta : keeper_meta) =
  let derived =
    match meta.runtime.last_blocker_class with
    | Some cls ->
        Some (runtime_blocker_surface_of_typed_class
                ~summary:meta.runtime.last_blocker cls)
    | None ->
        (* Fallback: legacy string-based classification *)
        match runtime_registry_entry config meta.name with
        | Some entry -> (
            match entry.last_failure_reason with
            | Some reason -> runtime_blocker_surface_of_failure_reason reason
            | None -> None)
        | None -> None
  in
  let derived =
    match derived with
    | Some blocker -> Some blocker
    | None -> (
        match blocker_class_of_string meta.runtime.last_blocker with
        | Some cls ->
            Some (runtime_blocker_surface_of_legacy_string
                    meta.runtime.last_blocker cls)
        | None
          when proactive_runtime_reason_is_current meta ->
            (match blocker_class_of_string meta.runtime.proactive_rt.last_reason with
             | Some cls ->
                 Some (runtime_blocker_surface_of_legacy_string
                         meta.runtime.proactive_rt.last_reason cls)
             | None -> None)
        | None -> runtime_blocker_surface_of_progress_narrative config meta)
  in
  derived

let runtime_blocker_fields_json (config : Coord_utils.config)
    (meta : keeper_meta) =
  match runtime_blocker_surface_opt config meta with
  | Some blocker ->
      [
        ("runtime_blocker_class", `String blocker.blocker_class);
        ("runtime_blocker_summary", `String blocker.summary);
        ("runtime_blocker_continue_gate", `Bool blocker.continue_gate);
      ]
  | None ->
      [
        ("runtime_blocker_class", `Null);
        ("runtime_blocker_summary", `Null);
        ("runtime_blocker_continue_gate", `Bool false);
      ]

let attention_fields_json (config : Coord_utils.config) (meta : keeper_meta) =
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let runtime_blocker = runtime_blocker_surface_opt config meta in
  let social_model_recognized =
    Keeper_social_model.is_known_social_model meta.social_model
  in
  let needs_attention, attention_reason, next_human_action =
    if pending_approval_count > 0 then
      (true, Some "approval_pending", Some "resolve_approval")
    else
      match runtime_blocker with
      | Some blocker when blocker.continue_gate ->
          (true, Some "continue_gate_required", Some "approve_or_reject_continue")
      | Some _ when meta.paused ->
          (true, Some "paused_blocked", Some "inspect_runtime_blocker")
      | Some blocker
        when is_timeout_budget_blocker_class blocker.blocker_class ->
          (true, Some "timeout_budget_exhausted", Some "inspect_timeout_budget")
      | Some _ ->
          (true, Some "runtime_blocked", Some "inspect_runtime_blocker")
      | None when meta.paused ->
          (true, Some "paused", Some "resume_or_review")
      | None when not social_model_recognized ->
          (true, Some "social_model_fallback", Some "review_social_model")
      | None ->
          (false, None, None)
  in
  [
    ("needs_attention", `Bool needs_attention);
    ("attention_reason", Json_util.string_opt_to_json attention_reason);
    ("next_human_action", Json_util.string_opt_to_json next_human_action);
  ]

let json_string_opt_member json key =
  match Yojson.Safe.Util.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let assoc_upsert fields key value =
  let rec loop acc = function
    | [] -> List.rev ((key, value) :: acc)
    | (existing_key, _) :: rest when String.equal existing_key key ->
        List.rev_append acc ((key, value) :: rest)
    | field :: rest -> loop (field :: acc) rest
  in
  loop [] fields

let attention_fields_with_runtime_trust attention_fields runtime_trust =
  let existing_needs_attention =
    match List.assoc_opt "needs_attention" attention_fields with
    | Some (`Bool value) -> value
    | _ -> false
  in
  let trust_needs_attention =
    Safe_ops.json_bool_opt "needs_attention" runtime_trust
    |> Option.value ~default:false
  in
  if existing_needs_attention || not trust_needs_attention then
    attention_fields
  else
    let attention_reason =
      match List.assoc_opt "attention_reason" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> (
          match json_string_opt_member runtime_trust "attention_reason" with
          | Some _ as value -> value
          | None -> json_string_opt_member runtime_trust "disposition_reason")
    in
    let next_human_action =
      match List.assoc_opt "next_human_action" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> (
          match json_string_opt_member runtime_trust "next_human_action" with
          | Some _ as value -> value
          | None -> (
              match json_string_opt_member runtime_trust "latest_next_action" with
              | Some _ as value -> value
              | None -> Some "inspect_runtime_trust"))
    in
    let attention_fields =
      assoc_upsert attention_fields "needs_attention" (`Bool true)
    in
    let attention_fields =
      assoc_upsert attention_fields "attention_reason"
        (Json_util.string_opt_to_json attention_reason)
    in
    assoc_upsert attention_fields "next_human_action"
      (Json_util.string_opt_to_json next_human_action)

let trimmed_string_json value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed

let non_empty_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let active_model_label_opt_of_meta (meta : keeper_meta) =
  Keeper_exec_status.active_model_label_of_meta meta |> non_empty_string_opt

let last_model_used_label_opt_of_meta (meta : keeper_meta) =
  if String.trim meta.runtime.usage.last_model_used = "" then None
  else active_model_label_opt_of_meta meta

let social_model_resolution_fields_json (meta : keeper_meta) =
  let resolved = Keeper_social_model.normalize_social_model meta.social_model in
  let recognized = Keeper_social_model.is_known_social_model meta.social_model in
  [
    ("social_model", `String resolved);
    ("configured_social_model", trimmed_string_json meta.social_model);
    ("social_model_recognized", `Bool recognized);
    ( "social_model_fallback",
      match Keeper_social_model.fallback_social_model meta.social_model with
      | Some fallback -> `String fallback
      | None -> `Null );
  ]

let social_runtime_fields_json (meta : keeper_meta) =
  let delivery_surface_view =
    Keeper_social_model.delivery_surface_view_of_meta meta
    |> Option.map Keeper_social_model.delivery_surface_to_string
  in
  let delivery_surface_view_source =
    Keeper_social_model.delivery_surface_view_source_of_meta meta
  in
  social_model_resolution_fields_json meta
  @ [
      ( "active_model_label",
        Json_util.string_opt_to_json (active_model_label_opt_of_meta meta) );
      ( "last_model_used_label",
        Json_util.string_opt_to_json (last_model_used_label_opt_of_meta meta) );
      ("last_speech_act", trimmed_string_json meta.runtime.last_speech_act);
      ("delivery_surface_view", Json_util.string_opt_to_json delivery_surface_view);
      ( "delivery_surface_view_source",
        Json_util.string_opt_to_json delivery_surface_view_source );
      ( "last_social_transition_reason",
        trimmed_string_json meta.runtime.last_social_transition_reason );
      ("last_blocker", trimmed_string_json meta.runtime.last_blocker);
      ("last_need", trimmed_string_json meta.runtime.last_need);
    ]

let runtime_surface_json config (meta : keeper_meta) =
  let keepalive_running = runtime_keepalive_running config meta in
  let fiber_health =
    match
      Keeper_registry.fiber_health_of ~base_path:config.base_path meta.name
    with
    | Fiber_unknown when keepalive_running -> Fiber_alive
    | health -> health
  in
  let phase =
    match runtime_registry_entry config meta.name with
    | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
    | None -> None
  in
  `Assoc
    ([
       ("paused", `Bool meta.paused);
       ("keepalive_running", `Bool keepalive_running);
       ("phase",
        match phase with
        | Some p -> `String p
        | None -> `Null);
       ( "fiber_health",
         `String (Keeper_exec_status.string_of_fiber_health fiber_health) );
     ]
     @ social_runtime_fields_json meta
     @ runtime_blocker_fields_json config meta
     @ attention_fields_json config meta)

let existing_path_json ?source path =
  let fields =
    [
      ("path", `String path);
      ("exists", `Bool (Fs_compat.file_exists path));
    ]
  in
  let fields =
    match source with
    | Some value -> ("source", `String value) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let optional_existing_path_json ?source = function
  | Some path -> existing_path_json ?source path
  | None -> `Null

let cascade_catalog_source_fields (resolution : Config_dir_resolver.resolution) =
  let source =
    Cascade_toml_materializer.source_info ~config_path:resolution.cascade.path
  in
  [
    ( "cascade_catalog_source_kind",
      `String (Cascade_toml_materializer.source_kind_to_string source.kind) );
    ("cascade_catalog_source_path", `String source.source_path);
    ("cascade_runtime_json_path", `String source.json_path);
    ("cascade_runtime_json_editable", `Bool source.raw_json_editable);
  ]

let override_field_source_json ~default_source_kind ~default_manifest_path detail =
  let default_missing =
    match detail.default_value with
    | `Null -> true
    | _ -> false
  in
  let default_manifest_exists =
    match default_manifest_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [
      ("field", `String detail.field);
      ("source", `String "live_meta");
      ("live_source", `String "runtime_overlay");
      ("default_source", Json_util.string_opt_to_json default_source_kind);
      ("default_source_kind", Json_util.string_opt_to_json default_source_kind);
      ("default_manifest_path", Json_util.string_opt_to_json default_manifest_path);
      ("default_manifest_exists", `Bool default_manifest_exists);
      ("default_missing", `Bool default_missing);
      ("default_value", detail.default_value);
      ("live_value", detail.live_value);
    ]

let source_provenance_json config (meta : keeper_meta) =
  let snapshot = keeper_default_source_snapshot meta.name in
  let override_details = live_override_details meta snapshot.defaults in
  let override_fields = List.map (fun detail -> detail.field) override_details in
  let resolution = Config_dir_resolver.resolve () in
  let live_meta_path = keeper_meta_path config meta.name in
  let default_manifest_path = snapshot.defaults.manifest_path in
  let default_source_kind = snapshot.source_kind in
  let default_config_error =
    Keeper_types_profile.keeper_toml_config_error_for_name meta.name
  in
  `Assoc
    ([
      ("live_meta_path", `String live_meta_path);
      ("live_meta", existing_path_json ~source:"runtime_overlay" live_meta_path);
      ("default_manifest_path", Json_util.string_opt_to_json default_manifest_path);
      ( "default_manifest",
        optional_existing_path_json ?source:default_source_kind default_manifest_path );
      ("default_source_kind", Json_util.string_opt_to_json default_source_kind);
      ( "default_config_error",
        Json_util.option_to_yojson
          Keeper_types_profile.keeper_toml_config_error_to_json
          default_config_error );
      ("active_config_root", `String resolution.config_root.path);
      ( "active_config_root_source",
        `String (Config_dir_resolver.source_to_string resolution.config_root.source) );
      ("config_resolution", Config_dir_resolver.to_json resolution);
      ("precedence", `List [ `String "live_meta"; `String "toml"; `String "persona" ]);
    ]
    @ cascade_catalog_source_fields resolution
    @ [
      ("has_live_override", `Bool (override_fields <> []));
      ("override_fields", string_list_to_json override_fields);
      ( "override_field_sources",
        `List
          (List.map
             (override_field_source_json ~default_source_kind ~default_manifest_path)
             override_details) );
    ])
