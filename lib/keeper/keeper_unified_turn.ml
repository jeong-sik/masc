(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec loop i =
      if i + needle_len > hay_len then false
      else if String.sub haystack i needle_len = needle then true
      else loop (i + 1)
    in
    loop 0

let string_contains_substring_ci ~(needle : string) (haystack : string) : bool =
  string_contains_substring
    ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let find_substring ~(needle : string) (haystack : string) : int option =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop i =
    if needle_len = 0 then Some 0
    else if i + needle_len > hay_len then None
    else if String.sub haystack i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop 0

(** Detect transient TCP/TLS errors that warrant retry with backoff.
    These patterns match OAS cascade error messages for connection-level failures.
    See #4523: Connection_reset/Broken_pipe/EOF from idle TCP teardown. *)
let transient_error_patterns =
  [ "Connection_reset"; "Broken pipe"; "End_of_file";
    "connection closed"; "Connection refused" ]

let is_transient_network_error (msg : string) : bool =
  List.exists
    (fun needle -> string_contains_substring ~needle msg)
    transient_error_patterns

(** Max transient retries (excluding the initial attempt).  Total attempts
    = 1 initial + max_transient_retries.  OAS internal retry is 3 per
    provider; this outer retry covers cases where all providers fail
    transiently (e.g. TCP keepalive expiry across all backends). *)
let max_transient_retries = 2

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Delays: 1s, 2s — total wait 3s before giving up. *)
let transient_backoff_sec (attempt : int) : float =
  Float.min 4.0 (1.0 *. Float.of_int (1 lsl (attempt - 1)))

let context_overflow_anchor = "available context size ("

type overflow_retry_plan = {
  retry_max_context : int;
  retry_generation : int;
}

let context_overflow_limit (msg : string) : int option =
  let lowered = String.lowercase_ascii msg in
  match find_substring ~needle:context_overflow_anchor lowered with
  | None -> None
  | Some anchor_idx ->
      let start_idx = anchor_idx + String.length context_overflow_anchor in
      let rec consume_digits idx =
        if idx >= String.length lowered then idx
        else
          match lowered.[idx] with
          | '0' .. '9' -> consume_digits (idx + 1)
          | _ -> idx
      in
      let end_idx = consume_digits start_idx in
      if end_idx = start_idx then None
      else
        String.sub lowered start_idx (end_idx - start_idx)
        |> int_of_string_opt

let meta_with_generation (meta : keeper_meta) ~(generation : int) : keeper_meta =
  if generation = meta.runtime.generation then meta
  else map_runtime (fun rt -> { rt with generation }) meta

let recover_context_overflow_retry
    ~(meta : keeper_meta)
    ~(base_dir : string)
    ~(primary_max_context : int)
    ~(error : string) : overflow_retry_plan option =
  match context_overflow_limit error with
  | None -> None
  | Some actual_limit ->
      let retry_max_context =
        if primary_max_context <= 0 then actual_limit
        else min primary_max_context actual_limit
      in
      let model = Keeper_exec_context.checkpoint_model_of_meta meta in
      match
        Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
          ~base_dir ~meta ~model
          ~primary_model_max_tokens:retry_max_context
      with
      | Some recovery ->
          Log.Keeper.warn
            "%s: context overflow retry prepared with compacted checkpoint (%d->%d tokens, max_context=%d, generation=%d)"
            meta.name recovery.compaction.before_tokens
            recovery.compaction.after_tokens
            retry_max_context recovery.turn_generation;
          Some
            {
              retry_max_context;
              retry_generation = recovery.turn_generation;
            }
      | None ->
          Log.Keeper.warn
            "%s: context overflow detected but checkpoint recovery was unavailable: %s"
            meta.name (short_preview error);
          None

let decision_channel_of_observation
    (observation : Keeper_world_observation.world_observation) : string =
  if observation.pending_mentions <> [] || observation.pending_board_events <> [] then
    "turn"
  else
    "proactive"

let selected_mode_of_result (result : Keeper_agent_run.run_result) : string =
  let text = String.trim result.response_text in
  if result.tools_used <> [] then "tool_use"
  else if text = "" then "noop"
  else if String.starts_with ~prefix:"SKIP:" text then "skip_text"
  else "text_response"

let observed_triggers_of_observation
    (observation : Keeper_world_observation.world_observation) : string list =
  let triggers = ref [] in
  let add trigger = triggers := trigger :: !triggers in
  if observation.pending_mentions <> [] then add "direct_mention";
  if observation.pending_board_events <> [] then add "board_activity";
  if observation.unclaimed_task_count > 0 then add "new_unclaimed_task";
  if observation.failed_task_count > 0 then add "failed_task";
  if observation.active_goals <> [] && observation.idle_seconds > 0 then
    add "idle_timeout_candidate";
  if Option.is_some observation.worktree_change_summary then add "worktree_change";
  List.rev !triggers

let observed_affordances_of_observation
    (observation : Keeper_world_observation.world_observation) : string list =
  let affordances = ref [] in
  let add affordance = affordances := affordance :: !affordances in
  if observation.pending_mentions <> [] then add "reply_in_room";
  if observation.pending_board_events <> [] then add "board_post_or_comment";
  if observation.unclaimed_task_count > 0 then add "task_claim";
  if observation.failed_task_count > 0 then add "task_audit";
  if Option.is_some observation.worktree_change_summary then add "inspect_worktree_delta";
  List.rev !affordances

let response_requests_confirmation (text : string) : bool =
  let trimmed = String.trim text in
  trimmed <> ""
  && (String.contains trimmed '?'
      || string_contains_substring_ci ~needle:"would you like" trimmed
      || string_contains_substring_ci ~needle:"do you want" trimmed
      || string_contains_substring_ci ~needle:"let me know" trimmed
      || string_contains_substring_ci ~needle:"어떻게 할까" trimmed
      || string_contains_substring_ci ~needle:"할까" trimmed)

let decision_id ~(meta : keeper_meta) ~(ts : float) ~(suffix_seed : string) : string =
  let digest =
    Digest.to_hex
      (Digest.string
         (Printf.sprintf "%s|%s|%.6f|%s"
            meta.name meta.runtime.trace_id ts suffix_seed))
  in
  Printf.sprintf "dec-%Ld-%s"
    (Int64.of_float (ts *. 1000.0))
    (String.sub digest 0 8)

let append_decision_record
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(latency_ms : int)
    ~(outcome : string)
    ~(selected_mode : string)
    ?social_state
    ?(result : Keeper_agent_run.run_result option = None)
    ?error
    () : unit =
  let now_ts = Time_compat.now () in
  let trigger_signals = observed_triggers_of_observation observation in
  let affordances = observed_affordances_of_observation observation in
  let tools_used =
    match result with
    | Some r -> r.tools_used
    | None -> []
  in
  let response_preview =
    match result with
    | Some r when String.trim r.response_text <> "" ->
        Some (short_preview r.response_text)
    | _ -> None
  in
  let tool_call_count =
    match result with
    | Some r -> r.tool_calls_made
    | None -> 0
  in
  let claim_executed = List.mem "keeper_task_claim" tools_used in
  let social_fields =
    match social_state with
    | None -> []
    | Some state ->
        let option_field key = function
          | Some value -> (key, `String value)
          | None -> (key, `Null)
        in
        [
          ("social_model", `String state.Social.social_model);
          ("belief_summary", `String state.belief_summary);
          option_field "active_desire" state.active_desire;
          option_field "current_intention" state.current_intention;
          option_field "blocker" state.blocker;
          option_field "need" state.need;
          ("speech_act", `String (Social.speech_act_to_string state.speech_act));
          ( "delivery_surface",
            `String
              (Social.delivery_surface_to_string state.delivery_surface) );
        ]
  in
  let suffix_seed =
    match response_preview, error with
    | Some preview, _ -> preview
    | None, Some err -> err
    | None, None -> selected_mode
  in
  let json =
    `Assoc
      ([
        ("id", `String (decision_id ~meta ~ts:now_ts ~suffix_seed));
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("audience", `String "internal_human_only");
        ("trace_id", `String meta.runtime.trace_id);
        ("generation", `Int meta.runtime.generation);
        ("keeper_name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("channel", `String (decision_channel_of_observation observation));
        ("outcome", `String outcome);
        ("selected_mode", `String selected_mode);
        ("selected_mode_source", `String "observed_result");
        ("latency_ms", `Int latency_ms);
        ("trigger_signals", `List (List.map (fun s -> `String s) trigger_signals));
        ("observed_affordances", `List (List.map (fun s -> `String s) affordances));
        ( "observation",
          `Assoc
            [
              ("pending_mentions", `Int (List.length observation.pending_mentions));
              ("pending_board_events", `Int (List.length observation.pending_board_events));
              ("active_goals", `Int (List.length observation.active_goals));
              ("idle_seconds", `Int observation.idle_seconds);
              ("context_ratio", `Float observation.context_ratio);
              ("unclaimed_task_count", `Int observation.unclaimed_task_count);
              ("failed_task_count", `Int observation.failed_task_count);
              ("active_agent_count", `Int observation.active_agent_count);
              ("worktree_change_detected", `Bool (Option.is_some observation.worktree_change_summary));
            ] );
        ("tool_call_count", `Int tool_call_count);
        ("tools_used", `List (List.map (fun s -> `String s) tools_used));
        ("claim_was_available", `Bool (observation.unclaimed_task_count > 0));
        ("claim_executed", `Bool claim_executed);
        ( "response_preview",
          match response_preview with
          | Some preview -> `String preview
          | None -> `Null );
        ( "response_requests_confirmation",
          `Bool
            (match result with
             | Some r -> response_requests_confirmation r.response_text
             | None -> false) );
        ( "error",
          match error with
          | Some reason -> `String reason
          | None -> `Null );
        ( "cdal_proof",
          match result with
          | Some { proof = Some p; _ } ->
              `Assoc
                [
                  ("run_id", `String p.Agent_sdk.Cdal_proof.run_id);
                  ( "result_status",
                    Agent_sdk.Cdal_proof.result_status_to_yojson p.result_status );
                  ("tool_trace_count", `Int (List.length p.tool_trace_refs));
                ]
          | _ -> `Null );
      ]
      @ social_fields)
  in
  try append_jsonl_line (keeper_decision_log_path config meta.name) json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Keeper.warn "append decision record failed for %s: %s"
        meta.name (Printexc.to_string exn)

(** Observe tool call history from run_result to update keeper metrics.
    No action_taken type — we observe what the agent did, not classify it. *)
let update_metrics_from_result (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ?(is_autonomous_turn = true)
    ?(update_proactive_rt = true)
    ?social_state
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let used_model_id =
    let strip_latest s =
      if String.length s > 7 && String.sub s (String.length s - 7) 7 = ":latest"
      then String.sub s 0 (String.length s - 7) else s
    in
    let used = strip_latest result.model_used in
    let cascade_models = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
    let cfgs = Llm_provider.Cascade_config.parse_model_strings cascade_models in
    match List.find_opt (fun (c : Llm_provider.Provider_config.t) ->
      c.model_id = result.model_used || c.model_id = used
    ) cfgs with
    | Some c -> c.model_id
    | None -> (match cfgs with c :: _ -> c.model_id | [] -> result.model_used)
  in
  let turn_cost =
    let pricing = Llm_provider.Pricing.pricing_for_model used_model_id in
    Llm_provider.Pricing.estimate_cost ~pricing
      ~input_tokens:result.usage.input_tokens
      ~output_tokens:result.usage.output_tokens ()
  in
  let has_tool_calls = result.tools_used <> [] in
  let has_text = String.trim result.response_text <> "" in
  let is_board_reactive = observation.pending_board_events <> [] in
  let is_mention_reactive = observation.pending_mentions <> [] in
  let rt = meta.runtime in
  let social_state : Social.social_state =
    Option.value social_state
      ~default:
        Social.
          {
            social_model = meta.social_model;
            belief_summary = "not_recorded";
            active_desire = None;
            current_intention = None;
            blocker = None;
            need = None;
            speech_act = Social.Inform;
            delivery_surface = Social.Visible_reply;
          }
  in
  {
    meta with
    updated_at = now_iso ();
    runtime = { rt with
      usage = {
        total_turns = rt.usage.total_turns + 1;
        total_input_tokens = rt.usage.total_input_tokens + result.usage.input_tokens;
        total_output_tokens = rt.usage.total_output_tokens + result.usage.output_tokens;
        total_tokens =
          rt.usage.total_tokens + Keeper_exec_context.total_tokens result.usage;
        total_cost_usd = rt.usage.total_cost_usd +. turn_cost;
        last_turn_ts = now_ts;
        last_model_used = result.model_used;
        last_input_tokens = result.usage.input_tokens;
        last_output_tokens = result.usage.output_tokens;
        last_total_tokens = Keeper_exec_context.total_tokens result.usage;
        last_latency_ms = latency_ms;
      };
      (* Proactive count: any turn that produced text or tools *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total
          + (if update_proactive_rt && (has_text || has_tool_calls) then 1 else 0);
        last_ts =
          (if update_proactive_rt && (has_text || has_tool_calls) then now_ts
           else rt.proactive_rt.last_ts);
        last_reason =
          (if not update_proactive_rt then rt.proactive_rt.last_reason
           else if has_tool_calls then
             Printf.sprintf "unified:tools=[%s]"
               (String.concat "," result.tools_used)
           else if has_text then "unified:text_response"
           else rt.proactive_rt.last_reason);
        last_preview =
          (if not update_proactive_rt then rt.proactive_rt.last_preview
           else if has_text then short_preview result.response_text
           else if has_tool_calls then
             Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
           else rt.proactive_rt.last_preview);
      };
      (* Autonomous action tracking from tool calls *)
      autonomous_action_count =
        rt.autonomous_action_count
        + (if is_autonomous_turn then List.length result.tools_used else 0);
      autonomous_turn_count =
        rt.autonomous_turn_count + (if is_autonomous_turn then 1 else 0);
      autonomous_text_turn_count =
        rt.autonomous_text_turn_count
        + (if is_autonomous_turn && has_text && not has_tool_calls then 1 else 0);
      autonomous_tool_turn_count =
        rt.autonomous_tool_turn_count
        + (if is_autonomous_turn && has_tool_calls then 1 else 0);
      board_reactive_turn_count =
        rt.board_reactive_turn_count + (if is_board_reactive then 1 else 0);
      mention_reactive_turn_count =
        rt.mention_reactive_turn_count + (if is_mention_reactive then 1 else 0);
      noop_turn_count =
        rt.noop_turn_count
        + (if is_autonomous_turn && not has_text && not has_tool_calls then 1 else 0);
      last_autonomous_action_at =
        (if is_autonomous_turn && has_tool_calls then now_iso ()
         else rt.last_autonomous_action_at);
      last_speech_act = Social.speech_act_to_string social_state.speech_act;
      last_blocker = Option.value ~default:"" social_state.blocker;
      last_need = Option.value ~default:"" social_state.need;
    };
  }

let append_metrics_snapshot ~(config : Room.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(latency_ms : int)
    ~(turn_cost : float)
    ~(turn_generation : int)
    ~(channel : string)
    ~(snapshot_source : string)
    ~(context_ratio : float)
    ~(context_tokens : int)
    ~(context_max : int)
    ~(message_count : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option) () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let work_kind =
    if result.tools_used <> [] then "tool_use"
    else if String.trim result.response_text <> "" then "text_turn"
    else "noop"
  in
  let metrics_store = keeper_metrics_store config meta.name in
  let cascade_json =
    match result.cascade_observation with
    | Some obs -> Oas_worker.cascade_observation_to_json obs
    | None ->
        `Assoc
          [
            ("cascade_name", `String meta.cascade_name);
            ("configured_labels", `List []);
            ("candidate_models", `List []);
            ("primary_model", `Null);
            ("selected_model", `String result.model_used);
            ("selected_model_raw", `String result.model_used);
            ("selected_index", `Null);
            ("fallback_hops", `Null);
            ("fallback_applied", `Bool false);
            ("attempts", `List []);
            ("fallback_events", `List []);
            ("attempt_details_available", `Bool false);
            ("attempt_details_source", `String "no_oas_observation");
          ]
  in
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String channel);
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String meta.runtime.trace_id);
        ("generation", `Int turn_generation);
        ("model_used", `String result.model_used);
        ("cascade", cascade_json);
        ( "usage",
          `Assoc
            [
              ("input_tokens", `Int result.usage.input_tokens);
              ("output_tokens", `Int result.usage.output_tokens);
              ("total_tokens",
               `Int (Keeper_exec_context.total_tokens result.usage));
            ] );
        ("latency_ms", `Int latency_ms);
        ("cost_usd", `Float turn_cost);
        ("context_ratio", `Float context_ratio);
        ("context_tokens", `Int context_tokens);
        ("context_max", `Int context_max);
        ("message_count", `Int message_count);
        ("continuity_state", `Null);
        ("continuity_summary", `String meta.continuity_summary);
        ("compacted", `Bool compaction.applied);
        ("compaction_before_tokens", `Int compaction.before_tokens);
        ("compaction_after_tokens", `Int compaction.after_tokens);
        ("compaction_saved_tokens", `Int compaction.saved_tokens);
        ("compaction_trigger",
          match compaction.trigger with
          | Some reason -> `String reason
          | None -> `Null);
        ("work_kind", `String work_kind);
        ("tool_call_count", `Int result.tool_calls_made);
        ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
        ("snapshot_source", `String snapshot_source);
        ("memory_check", memory_check_default_json ());
        ("handoff_performed",
         `Bool
           (match handoff_json with
            | Some (`Assoc fields) ->
                Safe_ops.json_bool ~default:false "performed" (`Assoc fields)
            | _ -> false));
        ("handoff",
         match handoff_json with
         | Some value -> value
         | None -> `Assoc [ ("performed", `Bool false) ]);
        ("cdal_proof",
         match result.proof with
         | Some p ->
           `Assoc [
             ("run_id", `String p.Agent_sdk.Cdal_proof.run_id);
             ("effective_mode",
              Agent_sdk.Execution_mode.to_yojson p.effective_execution_mode);
             ("result_status",
              Agent_sdk.Cdal_proof.result_status_to_yojson p.result_status);
             ("violation_count",
              `Int (List.length p.raw_evidence_refs));
             ("tool_trace_count",
              `Int (List.length p.tool_trace_refs));
             ("mode_source", `String p.mode_decision_source);
           ]
         | None -> `Null);
      ]
  in
  Dated_jsonl.append metrics_store snapshot

let broadcast_lifecycle_events ~(name : string)
    ~(turn_generation : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option) : unit =
  let now_ts = Time_compat.now () in
  (if compaction.applied then
     try
       Sse.broadcast
         (`Assoc
           [
             ("type", `String "keeper_compaction");
             ("name", `String name);
             ("generation", `Int turn_generation);
             ("before_tokens", `Int compaction.before_tokens);
             ("after_tokens", `Int compaction.after_tokens);
             ("saved_tokens", `Int compaction.saved_tokens);
             ( "trigger",
               match compaction.trigger with
               | Some reason -> `String reason
               | None -> `String compaction.decision );
             ("ts_unix", `Float now_ts);
           ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.error "compaction SSE broadcast failed: %s"
           (Printexc.to_string exn));
  match handoff_json with
  | Some ((`Assoc _ as handoff)) ->
      let from_generation =
        Safe_ops.json_int ~default:turn_generation "from_generation" handoff
      in
      let to_generation =
        Safe_ops.json_int ~default:(from_generation + 1) "to_generation" handoff
      in
      let to_model = Safe_ops.json_string ~default:"" "to_model" handoff in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "keeper_handoff");
               ("name", `String name);
               ("from_generation", `Int from_generation);
               ("to_generation", `Int to_generation);
               ("from_model", `Null);
               ("to_model",
                if String.trim to_model = "" then `Null else `String to_model);
               ("ts_unix", `Float now_ts);
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Keeper.error "handoff SSE broadcast failed: %s"
            (Printexc.to_string exn));
  | _ -> ()

let update_metrics_from_failure (meta : keeper_meta) ~(latency_ms : int)
    ~(reason : string) ?social_state () : keeper_meta =
  let now_ts = Time_compat.now () in
  let preview =
    let trimmed = String.trim reason in
    if trimmed = "" then "unified turn failed"
    else short_preview trimmed
  in
  {
    meta with
    updated_at = now_iso ();
    runtime = { meta.runtime with
      usage = { meta.runtime.usage with
        total_turns = meta.runtime.usage.total_turns + 1;
        last_turn_ts = now_ts;
        last_latency_ms = latency_ms;
      };
      proactive_rt = { meta.runtime.proactive_rt with
        last_reason = "unified:error:" ^ String.trim reason;
        last_preview = preview;
      };
      last_speech_act =
        (match social_state with
         | Some (state : Social.social_state) ->
             Social.speech_act_to_string state.speech_act
         | None -> meta.runtime.last_speech_act);
      last_blocker =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.blocker
         | None -> short_preview reason);
      last_need =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.need
         | None -> meta.runtime.last_need);
    };
  }

let run_unified_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int) : (keeper_meta, string) result =
  (* 1. Check API keys *)
  let model_labels = Keeper_coordination.effective_model_labels_for_turn meta in
  match ensure_api_keys_for_labels model_labels with
  | Error e -> Error e
  | Ok () ->
      let primary_max_context =
        Oas_model_resolve.resolve_primary_max_context model_labels
      in
      (* 2. Build unified prompt *)
      let system_prompt, user_message =
        Keeper_unified_prompt.build_prompt ~meta ~observation
      in
      let base_dir = session_base_dir config in
      (* Ensure session dir tree for filesystem fallback (issue #3019) *)
      Keeper_types.mkdir_p (Filename.concat base_dir meta.runtime.trace_id);
      (* 3. Derive parameters: cascade.json -> keeper env-var fallback *)
      let temperature =
        Cascade_inference.resolve_temperature
          ~cascade_name:"keeper_unified"
          ~fallback:Keeper_config.keeper_unified_temperature
      in
      let max_tokens =
        Cascade_inference.resolve_max_tokens
          ~cascade_name:"keeper_unified"
          ~fallback:Keeper_config.keeper_unified_max_tokens
      in
      let max_turns = Keeper_config.keeper_unified_max_turns () in
      let max_cost_usd = Keeper_config.keeper_tool_cost_max_usd () in
      (* 4. Build turn prompt callback: use our unified system prompt *)
      let build_turn_prompt ~base_system_prompt:_ ~messages:_
          : Keeper_agent_run.turn_prompt =
        (* Unified path already places soft context (continuity, worktree)
           in the user_message via Keeper_unified_prompt.build_prompt.
           No dynamic_context needed here. *)
        { system_prompt; dynamic_context = "" }
      in
      (* 5. Run via OAS Agent.run() with transient-error retry.
         Exponential backoff (1s, 2s, 4s) up to max_transient_retries.
         OAS already retries 3x per provider internally; this outer loop
         covers simultaneous backend failures (e.g. TCP keepalive expiry
         across all providers).  See #4523. *)
      let run_result, latency_ms =
        Keeper_exec_context.timed (fun () ->
          let do_run ?(is_retry = false) ~(turn_meta : keeper_meta) ~generation
              ~max_context () =
            Keeper_agent_run.run_turn ~config ~meta:turn_meta ~base_dir
              ~max_context ~build_turn_prompt
              ~user_message ~cascade_name:"keeper_unified"
              ~generation ~max_turns
              ~history_user_source:"world_state_prompt"
              ~history_assistant_source:"internal_assistant"
              ~temperature ~max_tokens
              ~max_cost_usd
              ~is_retry
              ()
          in
          let rec retry_loop attempt ~(turn_meta : keeper_meta) ~generation =
            match do_run ~is_retry:(attempt > 1) ~turn_meta ~generation
                    ~max_context:primary_max_context () with
            | Ok _ as ok -> ok
            | Error e when is_transient_network_error e
                           && attempt <= max_transient_retries ->
                let delay = transient_backoff_sec attempt in
                Log.Keeper.warn
                  "%s: transient network error (retry %d/%d), backoff %.0fs: %s"
                  meta.name attempt max_transient_retries delay
                  (short_preview e);
                Eio.Time.sleep (Eio_context.get_clock ()) delay;
                retry_loop (attempt + 1) ~turn_meta ~generation
            | Error e -> (
                match
                  recover_context_overflow_retry ~meta:turn_meta ~base_dir
                    ~primary_max_context ~error:e
                with
                | Some retry_plan ->
                    let retry_meta =
                      meta_with_generation turn_meta
                        ~generation:retry_plan.retry_generation
                    in
                    Eio.Fiber.yield ();
                    do_run ~is_retry:true ~turn_meta:retry_meta
                      ~generation:retry_plan.retry_generation
                      ~max_context:retry_plan.retry_max_context ()
                | None -> Error e)
          in
          retry_loop 1 ~turn_meta:meta ~generation)
      in
      match run_result with
      | Error e ->
          let social_state =
            Social.derive_failure_state ~meta ~observation ~reason:e
          in
          let updated_meta =
            update_metrics_from_failure meta ~latency_ms ~reason:e
              ~social_state ()
          in
          append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~outcome:"error" ~selected_mode:"error"
            ~social_state
            ~error:e ();
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error
                 "write_meta failed after unified turn failure: %s" msg);
          let base_path = config.base_path in
          Keeper_registry.increment_turn_failures ~base_path meta.name;
          let count = Keeper_registry.get_turn_failures ~base_path meta.name in
          let threshold =
            Runtime_params.get Governance_registry.keeper_max_turn_failures
          in
          if count >= threshold then begin
            Log.Keeper.error
              "%s: %d consecutive turn failures (threshold=%d), marking crashed"
              meta.name count threshold;
            let reason = Keeper_registry.Turn_consecutive_failures count in
            Keeper_registry.set_failure_reason ~base_path meta.name (Some reason);
            Keeper_registry.set_state ~base_path meta.name
              Keeper_registry.Crashed;
            Keeper_registry.record_crash ~base_path meta.name
              (Time_compat.now ())
              (Keeper_registry.failure_reason_to_string reason);
            Keeper_registry.record_error ~base_path meta.name
              (Printf.sprintf "turn_consecutive_failures(%d)" count)
          end;
          Error e
      | Ok result ->
          let result, social_state =
            Social.apply_to_result ~meta ~observation result
          in
          let used_model_id =
            let strip_latest s =
              if
                String.length s > 7
                && String.sub s (String.length s - 7) 7 = ":latest"
              then String.sub s 0 (String.length s - 7)
              else s
            in
            let used = strip_latest result.model_used in
            let cascade_models =
              Oas_model_resolve.models_of_cascade_name meta.cascade_name
            in
            let cfgs =
              Llm_provider.Cascade_config.parse_model_strings cascade_models
            in
            match
              List.find_opt
                (fun (c : Llm_provider.Provider_config.t) ->
                  c.model_id = result.model_used || c.model_id = used)
                cfgs
            with
            | Some c -> c.model_id
            | None ->
                (match cfgs with
                | c :: _ -> c.model_id
                | [] -> result.model_used)
          in
          let turn_cost =
            let pricing =
              Llm_provider.Pricing.pricing_for_model used_model_id
            in
            Llm_provider.Pricing.estimate_cost ~pricing
              ~input_tokens:result.usage.input_tokens
              ~output_tokens:result.usage.output_tokens ()
          in
          let lifecycle =
            apply_post_turn_lifecycle ~base_dir
              ~meta
              ~model:result.model_used
              ~primary_model_max_tokens:primary_max_context
              ~checkpoint:result.checkpoint
          in
          (* 6. Observe result and update metrics *)
          let updated_meta =
            update_metrics_from_result lifecycle.updated_meta ~latency_ms
              ~observation ~social_state result
          in
          (try
             let channel =
               if observation.pending_mentions <> [] || observation.pending_board_events <> [] then
                 "turn"
               else
                 "proactive"
             in
             append_metrics_snapshot ~config ~meta:updated_meta ~observation
               ~result ~latency_ms ~turn_cost
               ~turn_generation:lifecycle.turn_generation
               ~channel
               ~snapshot_source:"keeper_unified_turn"
               ~context_ratio:lifecycle.context_ratio
               ~context_tokens:lifecycle.context_tokens
               ~context_max:lifecycle.context_max
               ~message_count:lifecycle.message_count
               ~compaction:lifecycle.compaction
               ~handoff_json:lifecycle.handoff_json
               ()
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.error
                 "write metrics snapshot failed after unified turn: %s"
                 (Printexc.to_string exn));
          broadcast_lifecycle_events ~name:updated_meta.name
            ~turn_generation:lifecycle.turn_generation
            ~compaction:lifecycle.compaction
            ~handoff_json:lifecycle.handoff_json;
          append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~outcome:"success"
            ~selected_mode:(selected_mode_of_result result)
            ~social_state
            ~result:(Some result) ();
          (* 7. Persist updated meta *)
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error "write_meta failed after unified turn: %s" msg);
          (* 8. Handle stop reason *)
          (match result.stop_reason with
           | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
             Log.Keeper.warn
               "keeper:%s turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
               updated_meta.name turns_used limit;
             (* Do NOT increment turn_failures — this is not a crash.
                The keeper made progress and saved a checkpoint.
                Reset failures since the turn itself ran successfully. *)
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.Completed ->
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name);
          Ok updated_meta
