(** Progress/stall-oriented social-model implementation.

    This model reuses the validated header/tool parsing from
    [bdi_speech_v1], but it interprets tool evidence as progress ledger
    entries rather than something that always needs an additional visible
    narration. *)

open Keeper_types

module Types = Keeper_social_model_types
module Protocol = Keeper_social_model_protocol
module Bdi = Keeper_social_model_bdi_speech_v1

type progress_phase =
  | Advancing
  | Reactive
  | Stalled
  | Quiet

let model_name = Types.model_id_to_string Types.Magentic_ledger_v1

let reactive_signal_count
    (observation : Keeper_world_observation.world_observation) =
  List.length observation.pending_mentions
  + List.length observation.pending_board_events
  + List.length observation.pending_scope_messages

let backlog_count (observation : Keeper_world_observation.world_observation) =
  observation.unclaimed_task_count + observation.failed_task_count

let phase_of_turn ~(observation : Keeper_world_observation.world_observation)
    ~(has_progress_evidence : bool) ~(has_text_reply : bool) =
  if has_progress_evidence || has_text_reply then Advancing
  else if reactive_signal_count observation > 0 || backlog_count observation > 0
  then Reactive
  else if observation.active_goals <> [] && observation.idle_seconds >= 300 then
    Stalled
  else Quiet

let phase_to_string = function
  | Advancing -> "advancing"
  | Reactive -> "reactive"
  | Stalled -> "stalled"
  | Quiet -> "quiet"

let belief_summary_of_phase ~(phase : progress_phase)
    ~(observation : Keeper_world_observation.world_observation)
    ~(tool_count : int) =
  let parts =
    [
      "phase=" ^ phase_to_string phase;
      "reactive=" ^ string_of_int (reactive_signal_count observation);
      "backlog=" ^ string_of_int (backlog_count observation);
      "goals=" ^ string_of_int (List.length observation.active_goals);
      "tools=" ^ string_of_int tool_count;
      "idle=" ^ string_of_int observation.idle_seconds ^ "s";
    ]
    @
    if Option.is_some observation.worktree_change_summary then [ "worktree_delta" ]
    else []
  in
  "ledger:" ^ String.concat "; " parts

let active_desire_of_phase = function
  | Advancing -> Some "advance_task_progress"
  | Reactive -> Some "close_open_loop"
  | Stalled -> Some "recover_forward_motion"
  | Quiet -> Some "maintain_progress_ledger"

let current_intention_of_phase ~(phase : progress_phase) ~(tools_used : string list)
    ~(has_text_reply : bool) =
  if List.mem "keeper_task_claim" tools_used || List.mem "masc_claim_next" tools_used
  then Some "capture_next_task"
  else if tools_used <> [] then Some "record_progress_evidence"
  else if has_text_reply then Some "publish_progress_update"
  else
    match phase with
    | Reactive -> Some "triage_open_signal"
    | Stalled -> Some "request_replan"
    | Quiet -> Some "wait_for_delta"
    | Advancing -> Some "record_progress_evidence"

let blocker_of_phase ~(phase : progress_phase)
    ~(base_state : Types.social_state) ~(tools_used : string list)
    ~(has_text_reply : bool) =
  match base_state.speech_act with
  | Types.Request_help | Types.Defer when Option.is_some base_state.blocker ->
      base_state.blocker
  | _ -> (
      match phase with
      | Stalled when tools_used = [] && not has_text_reply ->
          Some "stalled_without_progress_evidence"
      | _ -> None)

let need_of_phase ~(phase : progress_phase)
    ~(base_state : Types.social_state) ~(tools_used : string list)
    ~(has_text_reply : bool) =
  match base_state.speech_act with
  | Types.Request_help when Option.is_some base_state.need -> base_state.need
  | _ -> (
      match phase with
      | Stalled -> Some "fresh_plan_or_external_delta"
      | Reactive when tools_used = [] && not has_text_reply ->
          Some "next_actionable_prioritization"
      | _ -> None)

let should_overlay_ledger = function
  | Types.Tool_only_stay_silent
  | Types.Tool_only_comment_board
  | Types.Tool_only_post_board
  | Types.Tool_only_broadcast
  | Types.Tool_only_claim_task
  | Types.Tool_only_visible_reply
  | Types.Missing_headers_fallback_visible_reply
  | Types.Invalid_headers_fallback_visible_reply
  | Types.Inferred_visible_reply
  | Types.Protocol_violation_no_tools_no_social_headers ->
      true
  | Types.Explicit_social_headers
  | Types.Protocol_violation_missing_social_headers
  | Types.Protocol_violation_invalid_social_headers
  | Types.Tool_only_progress_ledger
  | Types.Failure_run_error ->
      false

let overlay_ledger_state ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(has_text_reply : bool)
    (base_state : Types.social_state) =
  let has_progress_evidence =
    result.tools_used <> [] || Option.is_some observation.worktree_change_summary
  in
  let phase =
    phase_of_turn ~observation ~has_progress_evidence ~has_text_reply
  in
  {
    base_state with
    social_model = model_name;
    belief_summary =
      belief_summary_of_phase ~phase ~observation
        ~tool_count:(List.length result.tools_used);
    active_desire = active_desire_of_phase phase;
    current_intention =
      current_intention_of_phase ~phase ~tools_used:result.tools_used
        ~has_text_reply;
    blocker =
      blocker_of_phase ~phase ~base_state ~tools_used:result.tools_used
        ~has_text_reply;
    need =
      need_of_phase ~phase ~base_state ~tools_used:result.tools_used
        ~has_text_reply;
  }

let adapt_tool_only_turn (state : Types.social_state)
    (transition_reason : Types.transition_reason) =
  match transition_reason with
  | Types.Tool_only_visible_reply ->
      ( { state with
          speech_act = Types.Stay_silent;
          delivery_surface = Types.Silent;
        },
        Types.Tool_only_progress_ledger,
        true )
  | Types.Tool_only_stay_silent
  | Types.Tool_only_comment_board
  | Types.Tool_only_post_board
  | Types.Tool_only_broadcast
  | Types.Tool_only_claim_task ->
      ({ state with social_model = model_name }, transition_reason, true)
  | _ -> ({ state with social_model = model_name }, transition_reason, false)

let visible_response_body_of_result (result : Keeper_agent_run.run_result) =
  let _, response_body = Protocol.parse_header_block result.response_text in
  Keeper_text_processing.strip_internal_reply_markup response_body |> String.trim

let apply_to_result ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : Types.social_state option)
    (result : Keeper_agent_run.run_result) =
  let has_text_reply = visible_response_body_of_result result <> "" in
  let base_result, base_state, base_reason =
    Bdi.apply_to_result ~meta ~observation ~previous_state result
  in
  let state =
    if should_overlay_ledger base_reason then
      overlay_ledger_state ~observation ~result ~has_text_reply base_state
    else { base_state with social_model = model_name }
  in
  let state, transition_reason, suppress_visible_text =
    adapt_tool_only_turn state base_reason
  in
  let routed_result =
    if suppress_visible_text then { base_result with response_text = "" }
    else base_result
  in
  (routed_result, state, transition_reason)

let derive_failure_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : Types.social_state option)
    ~(reason : string) =
  let base_state, transition_reason =
    Bdi.derive_failure_state ~meta ~observation ~previous_state ~reason
  in
  let phase =
    phase_of_turn ~observation ~has_progress_evidence:false ~has_text_reply:false
  in
  ( { base_state with
      social_model = model_name;
      belief_summary = belief_summary_of_phase ~phase ~observation ~tool_count:0;
      active_desire = Some "recover_forward_motion";
      current_intention = Some "repair_failed_turn";
      blocker =
        (match String.trim reason with
        | "" -> Some "failed_without_detail"
        | _ -> base_state.blocker);
      need = Some "fresh_plan_or_operator_guidance";
    },
    transition_reason )
