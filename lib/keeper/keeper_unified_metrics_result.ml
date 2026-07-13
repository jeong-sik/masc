(** Success-path metric update for unified keeper cycle, extracted from
    keeper_unified_metrics.ml.

    Pure write-only side-effect: updates keeper_meta runtime fields
    based on a successful turn result. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support

let update_metrics_from_result (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ?(is_autonomous_turn = true)
    ?(update_proactive_rt = true)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let tool_names = Keeper_agent_result.tool_names result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
  in
  (* #9959: surface classification into Otel_metric_store exactly once per
     turn. Other [classify_usage_trust] call sites serialize the
     trust into JSONL but do not bump the counter. *)
  record_usage_trust ~keeper_name:meta.name ~trust:usage_trust;
  record_keeper_idle_seconds
    ~keeper_name:meta.name
    ~idle_seconds:observation.idle_seconds;
  (* [usage_trust] is anomaly provenance only. Provider-reported counters are
     retained verbatim in the runtime aggregate; a stale or invalidity label
     must never rewrite an observation to zero. *)
  let observed_input_tokens = result.usage.input_tokens in
  let observed_output_tokens = result.usage.output_tokens in
  let observed_total_tokens = Keeper_context_runtime.total_tokens result.usage in
  let turn_cost = estimate_usage_cost_usd result.usage in
  let substantive_tool_call_count = List.length tool_names in
  let has_substantive_tools = has_substantive_tool_calls tool_names in
  let has_text = String.trim result.response_text <> "" in
  (* RFC-0232: a budget-exhausted turn substitutes a synthetic continuation
     notice for the model reply (runtime_agent.ml MaxTurnsExceeded arm). That
     text is display-only ("no consumer may sniff this string"); gate the
     visible-output *preview* on the typed turn outcome rather than on the raw
     string being non-empty, so the dashboard stops showing the canned
     "Continuation checkpoint saved; ..." sentence as if it were work output.
     Scope is deliberately narrow: only last_preview is gated here — has_text
     still drives the visible/noop/autonomous counters unchanged. *)
  let is_visible_reply =
    Keeper_turn_outcome.equal
      (Keeper_turn_outcome.of_result_surface
         ~response_text:result.response_text result.stop_reason)
      Keeper_turn_outcome.Visible_reply
  in
  let validated_evidence = visible_run_validation result in
  let has_validated_evidence = Option.is_some validated_evidence in
  let visible_tool_signal_present =
    has_substantive_tools || has_validated_evidence
  in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let is_board_reactive = observation.pending_board_events <> [] in
  let is_mention_reactive =
    Keeper_world_observation_message_scope.has_kind
      Keeper_world_observation_message_scope.Mention observation.pending_messages
  in
  let has_meaningful_work =
    has_text || has_substantive_tools || has_validated_evidence
  in
  let rt = meta.runtime in
  (* #10474: proactive outcome counter for successful cycles. *)
  if update_proactive_rt && is_scheduled_autonomous_cycle then begin
    let outcome =
      if has_substantive_tools then "tool_called"
      else if is_noop_cycle ~has_text ~tools_used:tool_names
      then "noop"
      else "tool_called"
    in
    Otel_metric_store.inc_counter Keeper_metrics.(to_string ProactiveOutcome)
      ~labels:[ ("keeper", meta.name); ("outcome", outcome) ]
      ()
  end;
  let updated_meta = {
    meta with
    updated_at = now_iso ();
    runtime = { rt with
      usage = {
        total_turns = rt.usage.total_turns + 1;
        total_input_tokens = rt.usage.total_input_tokens + observed_input_tokens;
        total_output_tokens =
          rt.usage.total_output_tokens + observed_output_tokens;
        total_tokens =
          rt.usage.total_tokens + observed_total_tokens;
        total_cost_usd = rt.usage.total_cost_usd +. turn_cost;
        last_turn_ts = now_ts;
        last_input_tokens = observed_input_tokens;
        last_output_tokens = observed_output_tokens;
        last_total_tokens = observed_total_tokens;
        last_latency_ms = latency_ms;
      };
      (* Deterministic scheduled autonomous cycle accounting is separated from
         nondeterministic model output visibility. *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total
          + (if update_proactive_rt && is_scheduled_autonomous_cycle then 1 else 0);
        last_ts =
          (if update_proactive_rt
              && (is_scheduled_autonomous_cycle
                  || ((is_board_reactive || is_mention_reactive)
                      && has_meaningful_work))
           then now_ts
           else rt.proactive_rt.last_ts);
        visible_count_total =
          rt.proactive_rt.visible_count_total
          + (if update_proactive_rt
               && is_scheduled_autonomous_cycle
               && (has_text || visible_tool_signal_present)
             then 1
             else 0);
        last_visible_ts =
          (if update_proactive_rt
              && is_scheduled_autonomous_cycle
              && (has_text || visible_tool_signal_present)
           then now_ts
           else rt.proactive_rt.last_visible_ts);
        last_outcome =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             scheduled_autonomous_outcome_of_result ~has_text
               ~has_tool_calls:visible_tool_signal_present
           else rt.proactive_rt.last_outcome);
        last_reason =
          (if not update_proactive_rt then rt.proactive_rt.last_reason
           else if is_scheduled_autonomous_cycle then
             (if has_substantive_tools then
                Printf.sprintf "unified:tools=[%s]"
                  (String.concat "," tool_names)
              else if has_validated_evidence then
                (match validated_evidence with
                 | Some v ->
                   Printf.sprintf "unified:validated_evidence(ok=%b,file_write=%b,evidence=%d)"
                     v.ok v.has_file_write (List.length v.evidence)
                 | None -> "unified:validated_evidence(unreachable)")
              else if not has_text then
                "unified:"
                ^ proactive_cycle_outcome_to_string Proactive_silent
              else "unified:text_response")
           else
             (* Clear out previous error text if this was a successful reactive cycle *)
             if String.starts_with ~prefix:"unified:error:" rt.proactive_rt.last_reason
             then "unified:reactive_success"
             else rt.proactive_rt.last_reason);
        last_preview =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_preview
           else
             select_proactive_preview
               ~previous:rt.proactive_rt.last_preview
               ~has_text
               ~is_visible_reply
               ~has_substantive_tools
               ~tool_names
               ~response_text:result.response_text
               ~validated_evidence_preview:
                 (Option.map validated_evidence_preview validated_evidence));
        consecutive_noop_count =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             if is_noop_cycle ~has_text ~tools_used:tool_names
             then rt.proactive_rt.consecutive_noop_count + 1
             else 0
           else rt.proactive_rt.consecutive_noop_count);
      };
      (* Autonomous action tracking from tool calls *)
      autonomous_action_count =
        rt.autonomous_action_count
        + (if is_autonomous_turn then substantive_tool_call_count else 0);
      autonomous_turn_count =
        rt.autonomous_turn_count + (if is_autonomous_turn then 1 else 0);
      autonomous_text_turn_count =
        rt.autonomous_text_turn_count
        + (if is_autonomous_turn && has_text && not has_substantive_tools then 1 else 0);
      autonomous_tool_turn_count =
        rt.autonomous_tool_turn_count
        + (if is_autonomous_turn && has_substantive_tools then 1 else 0);
      board_reactive_turn_count =
        rt.board_reactive_turn_count + (if is_board_reactive then 1 else 0);
      mention_reactive_turn_count =
        rt.mention_reactive_turn_count + (if is_mention_reactive then 1 else 0);
      noop_turn_count =
        rt.noop_turn_count
        + (if is_autonomous_turn && not has_text && not has_substantive_tools
              && not has_validated_evidence then 1 else 0);
      (* This timestamp stays scoped to substantive tool actions.
         Validated evidence affects proactive visibility, but it does not
         redefine the autonomous action counter semantics. *)
      last_autonomous_action_at =
        (if is_autonomous_turn && has_substantive_tools
         then now_iso ()
         else rt.last_autonomous_action_at);
      (* A successful turn means the keeper is not blocked.
         Clear unconditionally so stale error strings from previous
         failures do not persist in the runtime JSON and mislead the
         dashboard into showing BLOCKED status. *)
      last_blocker = None;
      last_turn_tool_calls = [];
    };
  } in
  record_keeper_total_cost_usd
    ~keeper_name:updated_meta.name
    ~total_cost_usd:updated_meta.runtime.usage.total_cost_usd;
  updated_meta
