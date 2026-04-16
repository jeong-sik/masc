(** Keeper_unified_turn — Single entry point for keeper cycles via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  let rec loop offset =
    if offset = needle_len then true
    else if haystack.[start_idx + offset] <> needle.[offset] then false
    else loop (offset + 1)
  in
  loop 0

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec loop i =
      if i + needle_len > hay_len then false
      else if substring_matches_at ~needle haystack i then true
      else loop (i + 1)
    in
    loop 0

let string_contains_substring_ci ~(needle : string) (haystack : string) : bool =
  string_contains_substring
      ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let finalize_trajectory_acc (trajectory_acc : Trajectory.accumulator)
    (outcome : Trajectory.trajectory_outcome) : unit =
  try
    ignore (Trajectory.finalize trajectory_acc outcome)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Keeper.error "trajectory finalize failed (keeper cycle): %s"
        (Printexc.to_string exn)

(** {1 Retry & Side-Effect Safety}

    @boundary-contract
    - MASC owns: side-effect detection (blocking retry after mutating tools),
      cross-provider retry (2 attempts after all OAS per-provider retries
      exhaust), error reclassification for ambiguous outcomes.
    - OAS owns: per-provider retry (3 attempts), HTTP backoff, timeout
      handling, provider failover within a single cascade call.
    - Neither may: retry silently after a mutating tool succeeded (integrity
      over availability); duplicate OAS per-provider retry counts. *)

(** Detect transient network errors that warrant retry with short backoff.
    Uses structured [Oas.Error.sdk_error] pattern matching instead of
    substring matching on stringified error messages. *)
let is_transient_network_error (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (NetworkError _) -> true
  | Oas.Error.Api (Timeout _) -> true
  | Oas.Error.Api (Overloaded _) -> true
  | Oas.Error.Api (ServerError { status = 503; _ }) -> true
  | _ -> false

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a request with "Value looks like object, but can't find
    closing '}' symbol").  The LLM API never processed the request, so
    committed tool results are not at risk of duplication.

    These errors may recur with the same payload, so they are NOT
    eligible for same-turn retry.  They ARE eligible for auto-recovery
    when all committed tools are reconcile-safe (idempotent/board-like):
    the keeper's next heartbeat cycle will build a fresh prompt. *)
let is_server_rejected_parse_error (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (InvalidRequest { message }) ->
      let lower = String.lowercase_ascii message in
      (* Compound patterns to avoid false positives on generic messages
         like "Service closing" or "Can't find the specified tool".
         Each pattern targets a specific JSON parser error family. *)
      (string_contains_substring ~needle:"can't find closing" lower
       || string_contains_substring ~needle:"find end of" lower)
      || string_contains_substring ~needle:"unexpected character in json" lower
      || string_contains_substring ~needle:"unterminated" lower
      || string_contains_substring ~needle:"parse error" lower
  | _ -> false

let is_required_tool_contract_violation (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Agent (Oas.Error.CompletionContractViolation { contract; reason }) ->
      String.equal contract "require_tool_use"
      || let lower = String.lowercase_ascii reason in
         string_contains_substring
           ~needle:"tool_choice requested tool use"
           lower
         && string_contains_substring ~needle:"no tooluse block" lower
  | _ ->
      let lower = String.lowercase_ascii (Oas.Error.to_string err) in
      string_contains_substring
        ~needle:"completion contract [require_tool_use] violated"
        lower
      || ( string_contains_substring ~needle:"tool_choice requested tool use" lower
           && string_contains_substring ~needle:"no tooluse block" lower )

let is_auto_recoverable_turn_error (err : Oas.Error.sdk_error) : bool =
  is_transient_network_error err
  || is_server_rejected_parse_error err

let ambiguous_side_effect_error_prefix =
  "turn outcome ambiguous after committed mutating tool call(s)"

let committed_mutating_tools tool_names =
  tool_names
  |> dedupe_keep_order
  |> List.filter Keeper_exec_tools.has_mutating_side_effect

let is_ambiguous_side_effect_error (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Internal msg ->
      string_contains_substring
        ~needle:ambiguous_side_effect_error_prefix msg
  | _ -> false

let reclassify_error_after_side_effect
    ~(tool_names : string list)
    (err : Oas.Error.sdk_error) : Oas.Error.sdk_error =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = [] || is_ambiguous_side_effect_error err then err
  else
    let tools = String.concat ", " committed_tools in
    let original = short_preview (Oas.Error.to_string err) in
    Oas.Error.Internal
        (Printf.sprintf
         "%s: [%s]; retry disabled to avoid duplicate mutation; original_error=%s"
         ambiguous_side_effect_error_prefix tools original)

let post_commit_failure_kind_of_error (err : Oas.Error.sdk_error) =
  match err with
  | Oas.Error.Api (Timeout _) -> Keeper_registry.Post_commit_timeout
  | _ -> Keeper_registry.Post_commit_failure

let summarize_post_commit_failure
    ~(tool_names : string list)
    ~(kind : Keeper_registry.ambiguous_partial_commit_kind)
    (err : Oas.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  let tools = String.concat ", " committed_tools in
  let err_preview = short_preview (Oas.Error.to_string err) in
  (* Manual reconcile blocker removed — no "required/not required" branching.
     Evidence is recorded via Keeper_registry; the next turn's observation
     signals the failure for autonomous or operator-driven recovery. *)
  match kind with
  | Keeper_registry.Post_commit_timeout ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn timed out; evidence \
         recorded (error: %s)"
        tools err_preview
  | Keeper_registry.Post_commit_failure ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn failed; evidence \
         recorded (error: %s)"
        tools err_preview

let classify_post_commit_failure
    ~(tool_names : string list)
    ?kind
    (err : Oas.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = []
  then None
  else
    let resolved_kind =
      Option.value ~default:(post_commit_failure_kind_of_error err) kind
    in
    let reclassified =
      reclassify_error_after_side_effect ~tool_names:committed_tools err
    in
    let detail =
      summarize_post_commit_failure
        ~tool_names:committed_tools
        ~kind:resolved_kind
        err
    in
    Some
      ( reclassified,
        Keeper_registry.Ambiguous_partial_commit
          { kind = resolved_kind; detail } )

(** Max transient retries (excluding the initial attempt).  Total attempts
    = 1 initial + max_transient_retries.  OAS internal retry is 3 per
    provider; this outer retry covers cases where all providers fail
    transiently (e.g. TCP keepalive expiry across all backends). *)
let max_transient_retries = 2

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Delays: 1s, 2s — total wait 3s before giving up. *)
let transient_backoff_sec (attempt : int) : float =
  Float.min 4.0 (1.0 *. Float.of_int (1 lsl (attempt - 1)))

let oas_timeout_guard_sec = 1.0

let min_oas_timeout_budget_sec = 30.0

let bounded_oas_timeout_for_turn_budget_with_turn_budget ~(max_context : int)
    ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : float option =
  let usable_budget = remaining_turn_budget_s -. oas_timeout_guard_sec in
  if usable_budget < min_oas_timeout_budget_sec
  then None
  else
    let adaptive_timeout =
      Env_config_keeper.KeeperKeepalive.oas_timeout_for_context_with_turn_budget
        ~max_context ~max_turns
    in
    Some
      (Float.min adaptive_timeout usable_budget)

let bounded_oas_timeout_for_turn_budget ~(max_context : int)
    ~(remaining_turn_budget_s : float) : float option =
  bounded_oas_timeout_for_turn_budget_with_turn_budget ~max_context
    ~max_turns:Env_config_keeper.KeeperKeepalive.oas_max_turns_per_call
    ~remaining_turn_budget_s

(** Detect context overflow errors via structured OAS error types.
    Matches [ContextOverflow] (API-level) and [TokenBudgetExceeded]
    for input token budget exceeded.  Both are recoverable
    via checkpoint compaction + retry.

    @since 2.256.0 also matches TokenBudgetExceeded(Input) *)
let is_context_overflow (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (ContextOverflow _) -> true
  | Oas.Error.Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true
  | _ -> false

let is_cascade_exhausted_error (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Cascade_exhausted _)
  | Some (Oas_worker_named.Accept_rejected _) -> true
  | None ->
      match err with
      | Oas.Error.Internal msg ->
          string_contains_substring_ci
            ~needle:"all models failed" msg
          || string_contains_substring_ci
               ~needle:"response rejected by accept" msg
      | _ -> false

type overflow_retry_plan = {
  retry_max_context : int;
  retry_generation : int;
  compaction : compaction_event;
}

(** Recover from context overflow by compacting and reducing max_context.

    Extracts the token limit directly from the structured [ContextOverflow]
    error instead of re-parsing stringified error messages.
    No local token-budget math — OAS owns context budgeting.
    MASC only decides whether to compact and retry.

    @boundary-contract
    - MASC owns: "compact & retry?" decision (at most once per turn),
      extracting the limit from OAS structured errors, generation tracking.
    - OAS owns: context overflow detection, ContextOverflow/TokenBudgetExceeded
      error emission, checkpoint compaction algorithm, token budget enforcement.
    - Neither may: MASC must not invent token limits or run its own budget
      math; OAS must not auto-retry on overflow (MASC needs to decide). *)
let recover_context_overflow_retry
    ~(meta : keeper_meta)
    ~(base_dir : string)
    ~(max_cascade_context : int)
    ~(error : Oas.Error.sdk_error) : overflow_retry_plan option =
  let actual_limit =
    match error with
    | Oas.Error.Api (ContextOverflow { limit = Some limit; _ }) -> limit
    | Oas.Error.Agent (TokenBudgetExceeded { limit; _ }) -> limit
    | _ ->
      (* Overflow detected but limit not available — use 80% of cascade max
         as a conservative fallback. *)
      max 4096 (max_cascade_context * 4 / 5)
  in
  let retry_max_context =
    if max_cascade_context <= 0 then actual_limit
    else min max_cascade_context actual_limit
  in
  let model = Keeper_exec_context.checkpoint_model_of_meta meta in
  match
    Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
      ~base_dir ~meta ~model
      ~primary_model_max_tokens:retry_max_context
  with
  | Some recovery ->
      Log.Keeper.warn
        "%s: context overflow retry — compacted checkpoint (%d->%d tokens, max_context=%d, generation=%d)"
        meta.name recovery.compaction.before_tokens
        recovery.compaction.after_tokens
        retry_max_context recovery.turn_generation;
      Some
        {
          retry_max_context;
          retry_generation = recovery.turn_generation;
          compaction = recovery.compaction;
        }
  | None ->
      Log.Keeper.warn
        "%s: context overflow detected but checkpoint recovery unavailable: %s"
        meta.name (short_preview (Oas.Error.to_string error));
      None

let context_overflow_event_of_error
    ~(fallback_tokens : int)
    (err : Oas.Error.sdk_error) : Keeper_state_machine.event =
  match err with
  | Oas.Error.Agent (TokenBudgetExceeded { kind = "Input"; used; limit }) ->
      Keeper_state_machine.Context_overflow_detected
        {
          source = `Oas_signal;
          token_count = used;
          limit_tokens = Some limit;
        }
  | Oas.Error.Api (ContextOverflow { limit; _ }) ->
      Keeper_state_machine.Context_overflow_detected
        {
          source = `Prompt_rejected;
          token_count = Option.value ~default:(max 0 fallback_tokens) limit;
          limit_tokens = limit;
        }
  | _ ->
      Keeper_state_machine.Context_overflow_detected
        {
          source = `Oas_signal;
          token_count = max 0 fallback_tokens;
          limit_tokens = None;
        }

let pause_keeper_for_overflow
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(reason : string) : keeper_meta =
  let paused_meta =
    {
      meta with
      paused = true;
      updated_at = now_iso ();
    }
  in
  (match write_meta config paused_meta with
   | Ok () -> ()
   | Error err ->
       Log.Keeper.error
         "%s: overflow pause write_meta failed: %s"
         meta.name err);
  Keeper_registry.update_meta ~base_path:config.base_path meta.name paused_meta;
  dispatch_keeper_phase_event
    ~config
    ~keeper_name:meta.name
    Keeper_state_machine.Operator_pause;
  Log.Keeper.warn
    "%s: keeper paused after unresolved context overflow (%s)"
    meta.name reason;
  paused_meta

let sync_keeper_paused_state
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(paused : bool) : keeper_meta =
  let synced_meta =
    {
      meta with
      paused;
      updated_at = now_iso ();
    }
  in
  (match write_meta config synced_meta with
   | Ok () -> ()
   | Error err ->
     Log.Keeper.error
       "%s: keeper %s write_meta failed: %s"
       meta.name
       (if paused then "pause" else "resume")
       err);
  Keeper_registry.update_meta ~base_path:config.base_path meta.name synced_meta;
  dispatch_keeper_phase_event
    ~config
    ~keeper_name:meta.name
    (if paused
     then Keeper_state_machine.Operator_pause
     else Keeper_state_machine.Operator_resume);
  (if not paused then
    match Keeper_registry.get ~base_path:config.base_path meta.name with
    | Some entry -> Atomic.set entry.fiber_wakeup true
    | None -> ());
  synced_meta

let current_keeper_meta ~(config : Coord.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

let enqueue_reconcile_continue_gate
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(failure_reason : Keeper_registry.failure_reason)
    ~(committed_tools : string list)
    ~(error_detail : string) : string =
  let reason_text = Keeper_registry.failure_reason_to_string failure_reason in
  let input =
    `Assoc [
      ("kind", `String "reconcile_required");
      ("keeper_name", `String meta.name);
      ("failure_reason", `String reason_text);
      ("error_detail", `String error_detail);
      ("committed_tools", `List (List.map (fun tool -> `String tool) committed_tools));
    ]
  in
  Keeper_approval_queue.submit_pending
    ~keeper_name:meta.name
    ~tool_name:"keeper_continue_after_reconcile"
    ~input
    ~risk_level:Keeper_approval_queue.Critical
    ~on_resolution:(fun decision ->
      let latest_meta = current_keeper_meta ~config ~fallback_meta:meta in
      match decision with
      | Agent_sdk.Hooks.Approve
      | Agent_sdk.Hooks.Edit _ ->
        let _ = sync_keeper_paused_state ~config ~meta:latest_meta ~paused:false in
        Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name None;
        Keeper_registry.reset_turn_failures ~base_path:config.base_path meta.name;
        Log.Keeper.info
          "%s: reconcile continue gate approved; auto-resumed keeper"
          meta.name
      | Agent_sdk.Hooks.Reject reason ->
        let _ = sync_keeper_paused_state ~config ~meta:latest_meta ~paused:true in
        Keeper_registry.set_failure_reason
          ~base_path:config.base_path meta.name
          (Some failure_reason);
        Log.Keeper.warn
          "%s: reconcile continue gate rejected; keeper remains paused (%s)"
          meta.name reason)

(* Dedupe "mixed cascade context budget" log: the values are constant
   per (keeper_name, model_labels) because cascade config is static at
   startup.  Logging per turn produces 15-20 duplicates per keeper per
   minute under load. Track (name, primary, cascade_max) tuples we've
   already announced and skip subsequent identical log lines. *)
let cascade_budget_logged : (string * int * int, unit) Hashtbl.t =
  Hashtbl.create 16

let resolved_max_context_for_turn
    ~(meta : keeper_meta)
    (model_labels : string list) : int =
  let min_keeper_context = Keeper_config.min_keeper_context_tokens in
  let raw =
    match meta.max_context_override with
    | Some v ->
        Log.Keeper.debug "%s: using max_context_override=%d" meta.name v;
        v
    | None ->
        let primary =
          let resolved =
            Cascade_runtime.resolve_primary_max_context model_labels
          in
          Cascade_runtime.clamp_context_for_pure_local_labels
            ~labels:model_labels ~max_context:resolved
        in
        let cascade_max =
          let resolved =
            Cascade_runtime.resolve_max_cascade_context model_labels
          in
          Cascade_runtime.clamp_context_for_pure_local_labels
            ~labels:model_labels ~max_context:resolved
        in
        if primary < cascade_max then begin
          let key = (meta.name, primary, cascade_max) in
          if not (Hashtbl.mem cascade_budget_logged key) then begin
            Hashtbl.add cascade_budget_logged key ();
            Log.Keeper.info
              "%s: mixed cascade context budget primary=%d cascade_max=%d; using primary for initial turn budget"
              meta.name primary cascade_max
          end
        end;
        primary
  in
  if raw < min_keeper_context then begin
    Log.Keeper.warn "%s: resolved max_context=%d below minimum %d, clamped"
      meta.name raw min_keeper_context;
    min_keeper_context
  end else raw

let decision_channel_of_observation
    (observation : Keeper_world_observation.world_observation) : string =
  if observation.pending_mentions <> []
     || observation.pending_board_events <> []
     || observation.pending_scope_messages <> []
  then
    "turn"
  else
    "scheduled_autonomous"

let is_scheduled_autonomous_channel (channel : string) : bool =
  String.equal channel "scheduled_autonomous"
  || String.equal channel "proactive"

let is_scheduled_autonomous_cycle_of_observation
    (observation : Keeper_world_observation.world_observation) : bool =
  String.equal
    (decision_channel_of_observation observation)
    "scheduled_autonomous"

let scheduled_autonomous_outcome_of_result
    ~(has_text : bool) ~(has_tool_calls : bool) :
    scheduled_autonomous_cycle_outcome =
  match has_text, has_tool_calls with
  | false, false -> Proactive_silent
  | true, false -> Proactive_text_response
  | false, true -> Proactive_tool_use
  | true, true -> Proactive_mixed_response

let has_substantive_tool_calls (tools_used : string list) : bool =
  List.exists (fun name ->
    not (String.equal name "keeper_stay_silent")) tools_used

(** Observation-only tools that do not constitute productive work.
    A cycle using only these tools (or none) is a "noop" and triggers
    exponential cooldown backoff to prevent token waste. *)
let observation_only_tools =
  [ "keeper_stay_silent"
  ; "keeper_board_list"
  ; "keeper_context_status"
  ; "keeper_tool_search"
  ]

(** A cycle is noop when it produced no text AND all tools used (if any)
    are observation-only.  Productive cycles reset consecutive_noop_count. *)
let is_noop_cycle ~has_text ~(tools_used : string list) : bool =
  not has_text
  && List.for_all (fun name ->
       List.mem name observation_only_tools) tools_used

let visible_run_validation (result : Keeper_agent_run.run_result) :
    Agent_sdk.Raw_trace.run_validation option =
  match result.run_validation with
  | Some v when v.ok && (v.evidence <> [] || v.has_file_write) -> Some v
  | _ -> None

let has_visible_tool_signal (result : Keeper_agent_run.run_result) : bool =
  has_substantive_tool_calls result.tools_used
  || Option.is_some (visible_run_validation result)

let validated_evidence_preview
    (v : Agent_sdk.Raw_trace.run_validation) : string =
  if v.has_file_write then "(validated evidence: file_write)"
  else
    match v.tool_names with
    | [] -> "(validated evidence)"
    | names ->
      Printf.sprintf "(validated evidence: %s)"
        (String.concat ", " names)

let accountability_evidence_refs
    ~(trace_id : string)
    ~(turn_number : int)
    ~(result : Keeper_agent_run.run_result)
    ~(validated_evidence : Agent_sdk.Raw_trace.run_validation option)
    ~(turn_evidence : Yojson.Safe.t option) =
  let tool_refs =
    result.tools_used
    |> List.filter_map (fun tool_name ->
           let trimmed = String.trim tool_name in
           if trimmed = "" || String.equal trimmed "keeper_stay_silent" then None
           else Some ("tool:" ^ trimmed))
  in
  let validation_refs =
    match validated_evidence with
    | Some validation ->
        let base =
          validation.evidence
          |> List.map String.trim
          |> List.filter (fun entry -> entry <> "")
          |> List.map (fun entry -> "validation:" ^ entry)
        in
        if validation.has_file_write then
          "validation:file_write" :: base
        else
          base
    | None -> []
  in
  let turn_refs =
    let base = [ Printf.sprintf "turn:%s:%d" trace_id turn_number ] in
    match turn_evidence with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "after_hash" fields with
        | Some (`String hash) when String.trim hash <> "" ->
            ("git:" ^ String.trim hash) :: base
        | _ -> base)
    | _ -> base
  in
  tool_refs @ validation_refs @ turn_refs

let scheduled_autonomous_outcome_for_result
    (result : Keeper_agent_run.run_result) :
    scheduled_autonomous_cycle_outcome =
  scheduled_autonomous_outcome_of_result
    ~has_text:(String.trim result.response_text <> "")
    ~has_tool_calls:(has_visible_tool_signal result)

let selected_mode_of_result (result : Keeper_agent_run.run_result) : string =
  let text = String.trim result.response_text in
  if has_visible_tool_signal result then "tool_use"
  else if text = "" then "noop"
  else if String.starts_with ~prefix:"SKIP:" text then "skip_text"
  else "text_response"

let work_kind_of_selected_mode (selected_mode : string) : string =
  match selected_mode with
  | "tool_use" -> "tool_use"
  | "noop" -> "noop"
  | _ -> "text_turn"

let observed_triggers_of_observation
    (observation : Keeper_world_observation.world_observation) : string list =
  let triggers = ref [] in
  let add trigger = triggers := trigger :: !triggers in
  if observation.pending_mentions <> [] then add "direct_mention";
  if observation.pending_board_events <> [] then add "board_activity";
  if observation.pending_scope_messages <> [] then add "scope_message";
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
  if observation.pending_scope_messages <> [] then add "message_sweep";
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
            meta.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id) ts suffix_seed))
  in
  Printf.sprintf "dec-%Ld-%s"
    (Int64.of_float (ts *. 1000.0))
    (String.sub digest 0 8)

let append_decision_record
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(latency_ms : int)
    ?(semaphore_wait_ms : int = 0)
    ~(outcome : string)
    ~(selected_mode : string)
    ?social_state
    ?deliberation_execution
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
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int meta.runtime.generation);
        ("keeper_name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("channel", `String (decision_channel_of_observation observation));
        ("outcome", `String outcome);
        ("selected_mode", `String selected_mode);
        ("selected_mode_source", `String "observed_result");
        ("latency_ms", `Int latency_ms);
        ("semaphore_wait_ms", `Int semaphore_wait_ms);
        ("trigger_signals", `List (List.map (fun s -> `String s) trigger_signals));
        ("observed_affordances", `List (List.map (fun s -> `String s) affordances));
        ( "observation",
          `Assoc
            [
              ("pending_mentions", `Int (List.length observation.pending_mentions));
              ("pending_board_events", `Int (List.length observation.pending_board_events));
              ("pending_scope_messages", `Int (List.length observation.pending_scope_messages));
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
        ( "action_source",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.action_source_of_execution_result execution
              |> Keeper_deliberation.action_source_to_json
          | None -> `Null );
        ( "deliberation_execution",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.execution_result_to_json execution
          | None -> `Null );
        ( "response_preview",
          match response_preview with
          | Some preview -> `String preview
          | None -> `Null );
        ( "response_preview_2000",
          match result with
          | Some r when String.trim r.response_text <> "" ->
              `String (short_preview ~max_len:2000 r.response_text)
          | _ -> `Null );
        ( "response_requests_confirmation",
          `Bool
            (match result with
             | Some r -> response_requests_confirmation r.response_text
             | None -> false) );
        ( "error",
          match error with
          | Some reason -> `String reason
          | None -> `Null );
        ( "trace_ref",
          match result with
          | Some { trace_ref = Some trace_ref; _ } ->
              Agent_sdk.Raw_trace.run_ref_to_yojson trace_ref
          | _ -> `Null );
        ( "run_validation",
          match result with
          | Some { run_validation = Some validation; _ } ->
              Agent_sdk.Raw_trace.run_validation_to_yojson validation
          | _ -> `Null );
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
        ( "telemetry",
          match result with
          | Some r ->
              let surface_model_used = Keeper_agent_run.surface_model_used r in
              let cascade_fields =
                match r.cascade_observation with
                | Some co ->
                    [
                      ("cascade_name", `String co.cascade_name);
                      ("primary_model", match co.primary_model with Some m -> `String m | None -> `Null);
                      ("selected_model", match co.selected_model with Some m -> `String m | None -> `Null);
                      ("fallback_applied", `Bool co.fallback_applied);
                      ("fallback_hops", match co.fallback_hops with Some n -> `Int n | None -> `Int 0);
                      ("candidate_models", `List (List.map (fun s -> `String s) co.candidate_models));
                    ]
                | None -> []
              in
                let stop_reason_str =
                  match r.stop_reason with
                  | Oas_worker.Completed -> "completed"
                  | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
                      Printf.sprintf "turn_budget_exhausted(%d/%d)" turns_used limit
                  | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
                      (match tool_name with
                       | Some tool ->
                           Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                       | None ->
                           Printf.sprintf "mutation_boundary(%d)" turns_used)
                in
              let inference_fields =
                match r.inference_telemetry with
                | Some t ->
                    let timings_fields =
                      match t.timings with
                      | Some ti ->
                          [
                            ("prompt_ms", match ti.prompt_ms with Some v -> `Float v | None -> `Null);
                            ("predicted_ms", match ti.predicted_ms with Some v -> `Float v | None -> `Null);
                            ("provider_tokens_per_second", match ti.predicted_per_second with Some v -> `Float v | None -> `Null);
                            ("prompt_per_second", match ti.prompt_per_second with Some v -> `Float v | None -> `Null);
                            ("cache_n", match ti.cache_n with Some v -> `Int v | None -> `Null);
                          ]
                      | None -> []
                    in
                    [
                      ("system_fingerprint", match t.system_fingerprint with Some s -> `String s | None -> `Null);
                      ("reasoning_tokens", match t.reasoning_tokens with Some n -> `Int n | None -> `Null);
                      ("request_latency_ms", `Int t.request_latency_ms);
                    ] @ timings_fields
                | None -> []
              in
              `Assoc ([
                ("model_used", `String surface_model_used);
                ("turn_count", `Int r.turn_count);
                ("stop_reason", `String stop_reason_str);
                ("input_tokens", `Int r.usage.input_tokens);
                ("output_tokens", `Int r.usage.output_tokens);
                ("cache_creation_tokens", `Int r.usage.cache_creation_input_tokens);
                ("cache_read_tokens", `Int r.usage.cache_read_input_tokens);
                ("cost_usd", match r.usage.cost_usd with Some c -> `Float c | None -> `Null);
                ("tokens_per_second",
                  if latency_ms > 0 then
                    `Float (float_of_int r.usage.output_tokens /. (float_of_int latency_ms /. 1000.0))
                  else `Null);
              ] @ inference_fields @ cascade_fields)
          | None ->
              (* Partial telemetry for error turns: record what we know.
                 Without this, 90%+ of turns have no telemetry at all. *)
              let cascade_models =
                Keeper_model_labels.configured_model_labels_of_meta meta
              in
              let error_category =
                match error with
                | Some e when String.length e > 0 ->
                  let e_lower = String.lowercase_ascii e in
                  let starts_with prefix =
                    String.length e_lower >= String.length prefix
                    && String.sub e_lower 0 (String.length prefix) = prefix
                  in
                  let contains needle =
                    string_contains_substring ~needle e_lower
                  in
                  (* starts_with checks first (more specific), then contains *)
                  if starts_with "invalid request" then "invalid_request"
                  else if starts_with "network error" then "network_error"
                  else if starts_with "internal error" then "internal_error"
                  else if starts_with "input to" then "input_budget_exceeded"
                  (* contains checks second (broader, order matters) *)
                  else if contains "turn outcome ambiguous" then "ambiguous_side_effect"
                  else if contains "connection_failure"
                          || contains "connection refused" then "network_error"
                  else if contains "timeout" || contains "timed out" then "timeout"
                  else if contains "context length"
                          || contains "token budget" then "input_budget_exceeded"
                  else "other"
                | _ -> "unknown"
              in
              `Assoc [
                ("cascade_name", `String meta.cascade_name);
                ("candidate_models", `List (List.map (fun s -> `String s) cascade_models));
                ("error_category", `String error_category);
                ("outcome", `String "error");
              ] );
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
    ?social_transition_reason
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  (* Use cascade_observation.selected_model (canonical, no :latest suffix)
     instead of parsing model strings and stripping :latest manually.
     surface_model_used already extracts this from cascade_observation.
     Removes L3 (Cascade_config.parse_model_strings direct call) and
     L6 (strip_latest model ID parsing) boundary violations. See #5626. *)
  let used_model_id = surface_model_used in
  let turn_cost =
    let pricing = Llm_provider.Pricing.pricing_for_model used_model_id in
    Llm_provider.Pricing.estimate_cost ~pricing
      ~input_tokens:result.usage.input_tokens
      ~output_tokens:result.usage.output_tokens ()
  in
  let substantive_tool_call_count =
    result.tools_used
    |> List.filter (fun name ->
         not (String.equal name "keeper_stay_silent"))
    |> List.length
  in
  let has_substantive_tools = has_substantive_tool_calls result.tools_used in
  let has_text = String.trim result.response_text <> "" in
  let validated_evidence = visible_run_validation result in
  let has_validated_evidence = Option.is_some validated_evidence in
  let visible_tool_signal_present =
    has_substantive_tools || has_validated_evidence
  in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
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
        last_model_used = surface_model_used;
        last_input_tokens = result.usage.input_tokens;
        last_output_tokens = result.usage.output_tokens;
        last_total_tokens = Keeper_exec_context.total_tokens result.usage;
        last_latency_ms = latency_ms;
      };
      (* Deterministic scheduled autonomous cycle accounting is separated from
         nondeterministic model output visibility. *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total
          + (if update_proactive_rt && is_scheduled_autonomous_cycle then 1 else 0);
        last_ts =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then now_ts
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
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_reason
           else if has_substantive_tools then
             Printf.sprintf "unified:tools=[%s]"
               (String.concat "," result.tools_used)
           else if has_validated_evidence then
             (match validated_evidence with
              | Some v ->
                Printf.sprintf "unified:validated_evidence(ok=%b,file_write=%b,evidence=%d)"
                  v.ok v.has_file_write (List.length v.evidence)
              | None -> "unified:validated_evidence(unreachable)")
           else if not has_text then
             "unified:"
             ^ scheduled_autonomous_cycle_outcome_to_string Proactive_silent
            else if has_text then "unified:text_response"
            else rt.proactive_rt.last_reason);
        last_preview =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_preview
           else if has_text then short_preview result.response_text
           else if has_substantive_tools then
             Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
           else
             (match validated_evidence with
              | Some v -> validated_evidence_preview v
              | None -> rt.proactive_rt.last_preview)
          );
        (* Work discovery timestamp only advances when the keeper
           actually used tools in response to the nudge. This is
           intentional: the "Work Discovery Due" prompt block keeps
           being injected until the keeper takes visible action,
           preventing silent cycles from consuming the scan interval. *)
        last_work_discovery_ts =
          (if observation.work_discovery_due && has_substantive_tools then
             now_ts
           else rt.proactive_rt.last_work_discovery_ts);
        work_discovery_count =
          rt.proactive_rt.work_discovery_count
          + (if observation.work_discovery_due && has_substantive_tools then 1
             else 0);
        consecutive_noop_count =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             if is_noop_cycle ~has_text ~tools_used:result.tools_used
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
      consecutive_noop_count =
        (if is_autonomous_turn && not has_text && not has_substantive_tools
            && not has_validated_evidence
         then rt.consecutive_noop_count + 1
         else 0);
      (* This timestamp stays scoped to substantive tool actions.
         Validated evidence affects proactive visibility, but it does not
         redefine the autonomous action counter semantics. *)
      last_autonomous_action_at =
        (if is_autonomous_turn && has_substantive_tools
         then now_iso ()
         else rt.last_autonomous_action_at);
      last_speech_act = Social.speech_act_to_string social_state.speech_act;
      last_social_transition_reason =
        (match social_transition_reason with
         | Some reason -> String.trim reason
         | None -> rt.last_social_transition_reason);
      last_active_desire =
        Option.value ~default:"" social_state.active_desire;
      last_current_intention =
        Option.value ~default:"" social_state.current_intention;
      (* A successful turn means the keeper is not blocked.
         Clear unconditionally so stale error strings from previous
         failures do not persist in the runtime JSON and mislead the
         dashboard into showing BLOCKED status.  The social model's
         blocker field is a protocol-level signal; runtime last_blocker
         tracks whether the keeper can make progress. *)
      last_blocker = "";
      last_need = Option.value ~default:"" social_state.need;
    };
  }

let append_metrics_snapshot ~(config : Coord.config) ~(meta : keeper_meta)
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
    ~(handoff_json : Yojson.Safe.t option)
    ?deliberation_execution () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let selected_mode = selected_mode_of_result result in
  let work_kind = work_kind_of_selected_mode selected_mode in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  let scheduled_autonomous_outcome =
    if is_scheduled_autonomous_channel channel then
      Some (scheduled_autonomous_outcome_for_result result)
    else None
  in
  let metrics_store = keeper_metrics_store config meta.name in
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String channel);
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int turn_generation);
        ("model_used", `String surface_model_used);
        ("prompt_fingerprint", `String result.prompt_metrics.fingerprint);
        ("prompt", Keeper_agent_run.prompt_metrics_to_json result.prompt_metrics);
        ("ctx_composition", Keeper_agent_run.ctx_composition_to_json result.ctx_composition);
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
        ( "scheduled_autonomous_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
          | None -> `Null );
        ( "proactive_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
          | None -> `Null );
        ("tool_call_count", `Int result.tool_calls_made);
        ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
        ( "action_source",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.action_source_of_execution_result execution
              |> Keeper_deliberation.action_source_to_json
          | None -> `Null );
        ( "deliberation_execution",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.execution_result_to_json execution
          | None -> `Null );
        ("cascade",
         match result.cascade_observation with
         | Some observation -> Oas_worker.cascade_observation_to_json observation
         | None -> `Null);
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
        ( "trace_ref",
          match result.trace_ref with
          | Some trace_ref ->
              Agent_sdk.Raw_trace.run_ref_to_yojson trace_ref
          | None -> `Null );
        ( "run_validation",
          match result.run_validation with
          | Some validation ->
              Agent_sdk.Raw_trace.run_validation_to_yojson validation
          | None -> `Null );
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
        ("inference_telemetry",
         match result.inference_telemetry with
         | Some t ->
           Agent_sdk.Types.inference_telemetry_to_yojson t
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
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string) ?(is_transient = false) ?social_state
    ?social_transition_reason () : keeper_meta =
  ignore is_transient; (* Param retained for caller compatibility; no longer
                          used internally after zombie-fix #5594. *)
  let now_ts = Time_compat.now () in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let preview =
    let trimmed = String.trim reason in
    if trimmed = "" then "keeper cycle failed"
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
        count_total =
          meta.runtime.proactive_rt.count_total
          + (if is_scheduled_autonomous_cycle then 1 else 0);
        (* Always update last_ts on scheduled_autonomous attempts,
           including transient errors. Without this, transient errors
           (e.g. llama-server down) leave last_ts stale, causing
           cooldown_elapsed=false permanently → scheduled turns never
           resume. last_ts tracks attempts, not successes.
           Root cause of keeper zombie state: #5594. *)
        last_ts =
          if is_scheduled_autonomous_cycle then now_ts
          else meta.runtime.proactive_rt.last_ts;
        last_outcome =
          if is_scheduled_autonomous_cycle then Proactive_error
          else meta.runtime.proactive_rt.last_outcome;
        last_reason =
          if is_scheduled_autonomous_cycle
          then "unified:error:" ^ String.trim reason
          else meta.runtime.proactive_rt.last_reason;
        last_preview =
          if is_scheduled_autonomous_cycle then preview
          else meta.runtime.proactive_rt.last_preview;
      };
      last_speech_act =
        (match social_state with
         | Some (state : Social.social_state) ->
             Social.speech_act_to_string state.speech_act
         | None -> meta.runtime.last_speech_act);
      last_social_transition_reason =
        (match social_transition_reason with
         | Some value -> String.trim value
         | None -> meta.runtime.last_social_transition_reason);
      last_active_desire =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.active_desire
         | None -> meta.runtime.last_active_desire);
      last_current_intention =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.current_intention
         | None -> meta.runtime.last_current_intention);
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

let run_keeper_cycle ~(config : Coord.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int)
    ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
    ?(semaphore_wait_ms = 0)
    ?shared_context
    () : (keeper_meta, Oas.Error.sdk_error) result =
  (* 0. Phase gate + state-aware cascade routing *)
  let registry_base_path = config.base_path in
  let previous_social_state = Social.previous_state_of_meta meta in
  match Keeper_registry.get_phase ~base_path:registry_base_path meta.name with
  | Some phase when not (Keeper_state_machine.can_execute_turn phase) ->
      Log.Keeper.info
        "%s: keeper cycle skipped in non-executable phase=%s"
        meta.name (Keeper_state_machine.phase_to_string phase);
      Ok meta
  | phase_opt ->
      (* State-aware cascade routing (TLA+ KeeperCoreTriad.SelectCascade) *)
      let effective_cascade_name =
        let phase = match phase_opt with
          | Some p -> p
          | None ->
              Log.Keeper.warn "%s: registry phase lookup returned None, defaulting to Failing"
                meta.name;
              Keeper_state_machine.Failing
        in
        let routing = Keeper_cascade_routing.select_cascade
          ~base_cascade:meta.cascade_name ~phase
        in
        Log.Keeper.debug "%s: cascade routing: %s -> %s (reason: %s)"
          meta.name meta.cascade_name routing.effective_cascade routing.reason;
        routing.effective_cascade
      in
      (* 1. Check API keys *)
      let meta_for_cascade = { meta with cascade_name = effective_cascade_name } in
      let model_labels = Keeper_coordination.effective_model_labels_for_turn meta_for_cascade in
      match ensure_api_keys_for_labels model_labels with
      | Error e -> Error (Oas.Error.Internal e)
      | Ok () ->
      ignore (Cascade_runtime.refresh_local_discovery_if_possible model_labels);
      let max_context =
        resolved_max_context_for_turn ~meta model_labels
      in
      (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
      Eio.Fiber.yield ();
      (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
      let system_prompt, user_message =
        Keeper_unified_prompt.build_prompt ~meta ~base_path:config.base_path
          ~observation ()
      in
      Eio.Fiber.yield ();
      let base_dir = session_base_dir config in
      (* Ensure session dir tree for filesystem fallback (issue #3019) *)
      Keeper_types.mkdir_p (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      let masc_root = Coord.masc_root_dir config in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~generation:meta.runtime.generation
      in
      (* 3. Derive parameters: cascade.json -> keeper env-var fallback *)
      let temperature =
        Cascade_inference.resolve_temperature
          ~cascade_name:effective_cascade_name
          ~fallback:Keeper_config.keeper_unified_temperature
      in
      let max_tokens =
        let raw = Cascade_inference.resolve_max_tokens
          ~cascade_name:effective_cascade_name
          ~fallback:Keeper_config.keeper_unified_max_tokens
        in
        (* Capability gate: clamp to provider ceiling (TLA+ S3) *)
        Cascade_inference.clamp_max_tokens_to_ceiling
          ~provider_ceiling:(Some max_context) raw
      in
      (* max_turns: defer to OAS default (Types.default_agent_config.max_turns).
         MASC does not hardcode agent runtime budgets. *)
      let max_cost_usd = Keeper_config.keeper_tool_cost_max_usd () in
      (* 4. Build turn prompt callback: use our unified system prompt *)
      let build_turn_prompt ~base_system_prompt:_ ~messages:_
          : Keeper_agent_run.turn_prompt =
        (* Unified path already places soft context (continuity, worktree)
           in the user_message via Keeper_unified_prompt.build_prompt.
           No dynamic_context needed here. *)
        { system_prompt; dynamic_context = "" }
      in
      (* 5. Run via OAS Agent.run() with transient-error retry *)
      (* Track whether side-effecting tool calls have been executed.
         If a board_post/comment/shell/file edit succeeded and then a
         transient error occurs, retrying would replay those tool calls and
         produce duplicates. In that case, we propagate the error instead of
         retrying.

         Uses a per-turn observer via [add_tool_call_observer] instead of
         wrapping the global [on_keeper_tool_call] ref. Observer delivery is
         process-global, so the callback must filter on [keeper_name] to avoid
         cross-turn contamination when multiple keepers execute concurrently. *)
      let mutating_tools_committed = ref [] in
      let post_commit_failure_reason = ref None in
      let paused_meta_override = ref None in
      let current_turn_overflow_blocker = ref None in
      let side_effect_observer ~keeper_name ~tool_name ~input ~success =
        if success
           && String.equal keeper_name meta.name
           && Keeper_exec_tools.has_mutating_side_effect_with_input
                ~tool_name ~input
        then
          mutating_tools_committed := tool_name :: !mutating_tools_committed
      in
      let mark_paused_after_overflow ~run_meta ~reason =
        let paused_meta =
          pause_keeper_for_overflow
            ~config
            ~meta:run_meta
            ~reason
        in
        paused_meta_override := Some paused_meta
      in
      Keeper_exec_tools.add_tool_call_observer side_effect_observer;
      let event_bus_sub =
        match Keeper_event_bus.get () with
        | Some bus ->
          Some (Agent_sdk.Event_bus.subscribe
                  ~filter:(Agent_sdk.Event_bus.filter_agent meta.name) bus)
        | None -> None
      in
      let evidence_before_hash =
        try Keeper_evidence.snapshot_before_turn
          ~base_path:config.base_path ~keeper_name:meta.name
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None
      in
      let unsubscribe_event_bus () =
        match event_bus_sub, Keeper_event_bus.get () with
        | Some sub, Some bus -> Agent_sdk.Event_bus.unsubscribe bus sub
        | _ -> ()
      in
      (* Mark turn boundary for the composite observer (issue #7122).
         [mark_turn_started] installs [current_turn_observation = Some _]
         so the composite observer can surface live in-turn states like
         [`Executing`]. The matching [mark_turn_finished] in the finally
         block clears the field, preventing stale state on idle keepers. *)
      Keeper_registry.mark_turn_started
        ~base_path:config.base_path meta.name;
      Keeper_registry.mark_turn_measurement
        ~base_path:config.base_path meta.name;
      (match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some { current_turn_observation = Some { measurement = Some _; _ }; _ } ->
           Keeper_registry.set_turn_decision_stage
             ~base_path:config.base_path meta.name
             Keeper_registry.Decision_guard_ok
       | _ -> ());
      let run_result, latency_ms =
        Fun.protect ~finally:(fun () ->
          Keeper_exec_tools.remove_tool_call_observer side_effect_observer;
          unsubscribe_event_bus ();
          Keeper_registry.mark_turn_finished
            ~base_path:config.base_path meta.name)
        (fun () ->
        Keeper_exec_context.timed (fun () ->
          let clock = Eio_context.get_clock () in
          let timeout_sec =
            Env_config_keeper.KeeperKeepalive.turn_timeout_sec
          in
          let turn_deadline = Eio.Time.now clock +. timeout_sec in
          let remaining_turn_budget_s () =
            Float.max 0.0 (turn_deadline -. Eio.Time.now clock)
          in
          let keeper_profile =
            Keeper_types_profile.load_keeper_profile_defaults meta.name
          in
          let do_run ~run_meta ~max_context ~run_generation ~is_retry
              ~oas_timeout_s =
            let max_idle_turns, max_turns =
              match channel with
              | Keeper_world_observation.Reactive ->
                  ( Env_config_keeper.KeeperKeepalive.max_idle_turns_reactive,
                    Keeper_types_profile.effective_max_turns_per_call
                      keeper_profile )
              | Keeper_world_observation.Scheduled_autonomous ->
                  ( Env_config_keeper.KeeperKeepalive.max_idle_turns_autonomous,
                    Keeper_types_profile
                    .effective_max_turns_per_call_scheduled_autonomous
                      keeper_profile )
            in
            Keeper_agent_run.run_turn ~config ~meta:run_meta ~base_dir
              ~max_context ~build_turn_prompt
              ~user_message ~cascade_name:effective_cascade_name
              ?provider_filter:(Env_config_keeper.KeeperCascade.provider_allowlist ())
              ~generation:run_generation
              ~max_turns
              ~max_idle_turns
              ~history_user_source:"world_state_prompt"
              ~history_assistant_source:"internal_assistant"
              ~temperature ~max_tokens
              ~oas_timeout_s
              ?max_cost_usd
              ~trajectory_acc
              ~is_retry
              ?shared_context
              ?event_bus:(Keeper_event_bus.get ())
              ()
          in
          let rec retry_loop ~run_meta ~max_context ~run_generation
              ~attempt ~is_retry
              ~overflow_retry_used =
            let mark_terminal_error err =
              if is_cascade_exhausted_error err then
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_exhausted
              else
                Keeper_registry.set_turn_phase
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Turn_finalizing
            in
            let max_turns =
              match channel with
              | Keeper_world_observation.Reactive ->
                  Keeper_types_profile.effective_max_turns_per_call
                    keeper_profile
              | Keeper_world_observation.Scheduled_autonomous ->
                  Keeper_types_profile
                  .effective_max_turns_per_call_scheduled_autonomous
                    keeper_profile
            in
            let attempt_result =
              match
                bounded_oas_timeout_for_turn_budget_with_turn_budget
                  ~max_turns
                  ~max_context
                  ~remaining_turn_budget_s:(remaining_turn_budget_s ())
              with
              | None ->
                  Error
                    (Oas.Error.Api
                       (Timeout
                          {
                            message =
                              Printf.sprintf
                                "Turn wall-clock budget exhausted before retry (remaining=%.1fs)"
                                (remaining_turn_budget_s ());
                          }))
              | Some oas_timeout_s ->
                  Keeper_registry.set_turn_cascade_state
                    ~base_path:config.base_path meta.name
                    Keeper_registry.Cascade_trying;
                  do_run ~run_meta ~max_context ~run_generation ~is_retry
                    ~oas_timeout_s
            in
            match attempt_result with
            | Ok result ->
                let selected_model =
                  match result.cascade_observation with
                  | Some observation -> observation.selected_model
                  | None -> None
                in
                Keeper_registry.set_turn_selected_model
                  ~base_path:config.base_path meta.name
                  selected_model;
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_done;
                Ok result
            | Error err ->
                let committed_tools =
                  committed_mutating_tools !mutating_tools_committed
                in
                if committed_tools <> []
                   && Keeper_tool_registry.all_tools_reconcile_safe
                        committed_tools
                   && (is_auto_recoverable_turn_error err
                       || is_required_tool_contract_violation err)
                then begin
                  (* All committed tools are board-like (duplicate-tolerant)
                     AND the failure is transient or the server rejected the
                     request body before processing (parse error).  Parse
                     errors mean the LLM never saw the request, so no risk
                     of duplicate processing.  The keeper's next cycle will
                     build a fresh prompt that may avoid the parse issue. *)
                  let err_preview = short_preview (Oas.Error.to_string err) in
                  let reason =
                    if is_server_rejected_parse_error err then "server parse rejection"
                    else if is_required_tool_contract_violation err then
                      "required tool contract violation"
                    else "transient error"
                  in
                  Log.Keeper.warn
                    "%s: %s after committed reconcile-safe tool(s) [%s] — auto-recovering (error: %s)"
                    meta.name reason
                    (String.concat ", " committed_tools)
                    err_preview;
                  mark_terminal_error err;
                  Error err
                end else if committed_tools <> [] then begin
                  let reclassified, failure_reason =
                    match
                      classify_post_commit_failure
                        ~tool_names:committed_tools
                        err
                    with
                    | Some classified -> classified
                    | None ->
                        ( reclassify_error_after_side_effect
                            ~tool_names:committed_tools err,
                          Keeper_registry.Ambiguous_partial_commit {
                            kind = Keeper_registry.Post_commit_failure;
                            detail =
                              summarize_post_commit_failure
                                ~tool_names:committed_tools
                                ~kind:Keeper_registry.Post_commit_failure
                                err;
                          } )
                  in
                  post_commit_failure_reason := Some failure_reason;
                  let err_preview = short_preview (Oas.Error.to_string err) in
                  if is_transient_network_error err then
                    Log.Keeper.error
                      "%s: transient provider error after committed mutating tool call(s) [%s] — treating as integrity failure, skipping retry to prevent duplicate (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview
                  else
                    Log.Keeper.error
                      "%s: error after committed mutating tool call(s) [%s] — turn outcome is ambiguous and requires reconcile (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview;
                  mark_terminal_error reclassified;
                  Error reclassified
                end else if is_transient_network_error err
                              && attempt <= max_transient_retries then begin
                  let delay = transient_backoff_sec attempt in
                  Log.Keeper.warn
                    "%s: transient network error cascade=%s max_context=%d retry=%d/%d backoff=%.0fs: %s"
                    meta.name effective_cascade_name max_context
                    attempt max_transient_retries delay
                    (short_preview (Oas.Error.to_string err));
                  Eio.Time.sleep clock delay;
                  retry_loop ~run_meta ~max_context ~run_generation
                    ~attempt:(attempt + 1)
                    ~is_retry:true ~overflow_retry_used
                end else if is_context_overflow err then begin
                  dispatch_keeper_phase_event
                    ~config
                    ~keeper_name:meta.name
                    (context_overflow_event_of_error
                       ~fallback_tokens:max_context
                       err);
                  if not overflow_retry_used then
                    match
                      recover_context_overflow_retry
                        ~meta:run_meta
                        ~base_dir
                        ~max_cascade_context:max_context
                        ~error:err
                    with
                    | Some retry_plan ->
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_compacting;
                        current_turn_overflow_blocker :=
                          Some (Oas.Error.to_string err);
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          Keeper_state_machine.Compaction_started;
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          (Keeper_state_machine.Compaction_completed
                             {
                               before_tokens =
                                 retry_plan.compaction.before_tokens;
                               after_tokens =
                                 retry_plan.compaction.after_tokens;
                             });
                        Keeper_registry.prepare_turn_retry_after_compaction
                          ~base_path:config.base_path meta.name;
                        let retry_meta =
                          if retry_plan.retry_generation = run_meta.runtime.generation
                          then run_meta
                          else
                            map_runtime
                              (fun rt ->
                                {
                                  rt with
                                  generation = retry_plan.retry_generation;
                                })
                              run_meta
                        in
                        Eio.Fiber.yield ();
                        retry_loop
                          ~run_meta:retry_meta
                          ~max_context:retry_plan.retry_max_context
                          ~run_generation:retry_plan.retry_generation
                          ~attempt:1
                          ~is_retry:true
                          ~overflow_retry_used:true
                    | None ->
                        mark_paused_after_overflow
                          ~run_meta
                          ~reason:"auto_compact_recovery_unavailable";
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_finalizing;
                        Error err
                  else begin
                    mark_paused_after_overflow
                      ~run_meta
                      ~reason:"overflow_persisted_after_auto_compact_retry";
                    Keeper_registry.set_turn_phase
                      ~base_path:config.base_path meta.name
                      Keeper_registry.Turn_finalizing;
                    Error err
                  end
                end
                else begin
                  mark_terminal_error err;
                  Error err
                end
          in
          (* Wall-clock timeout guards against indefinite TCP-level hangs
             from upstream LLM providers. Without this, a single stalled
             connection blocks the keeper fiber forever. *)
          (try
            Eio.Time.with_timeout_exn clock timeout_sec
              (fun () ->
                retry_loop ~run_meta:meta ~max_context
                  ~run_generation:generation ~attempt:1
                  ~is_retry:false ~overflow_retry_used:false)
          with Eio.Time.Timeout ->
            let msg =
              Printf.sprintf
                "Turn wall-clock timeout after %.0fs (MASC_KEEPER_TURN_TIMEOUT_SEC)"
                timeout_sec
            in
            Log.Keeper.error "%s: %s" meta.name msg;
            let committed_tools =
              committed_mutating_tools !mutating_tools_committed
            in
            if committed_tools <> []
               && Keeper_tool_registry.all_tools_reconcile_safe
                    committed_tools
            then begin
              (* Timeouts are inherently transient — the provider was
                 reachable (tools executed) but took too long.  Board-only
                 committed tools are duplicate-tolerant, so we auto-recover
                 instead of recording an integrity failure.  Unlike the
                 retry_loop path, no is_transient check is needed: a
                 wall-clock timeout after successful tool execution is
                 always transient by nature. *)
              Log.Keeper.warn
                "%s: turn wall-clock timeout after committed reconcile-safe tool(s) [%s] — auto-recovering (timeout: %s)"
                meta.name
                (String.concat ", " committed_tools)
                msg;
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error (Oas.Error.Api (Timeout { message = msg }))
            end else if committed_tools <> [] then begin
              let timeout_err =
                Oas.Error.Api (Timeout { message = msg })
              in
              let reclassified, failure_reason =
                match
                  classify_post_commit_failure
                    ~tool_names:committed_tools
                    ~kind:Keeper_registry.Post_commit_timeout
                    timeout_err
                with
                | Some classified -> classified
                | None ->
                    ( reclassify_error_after_side_effect
                        ~tool_names:committed_tools
                        timeout_err,
                      Keeper_registry.Ambiguous_partial_commit {
                        kind = Keeper_registry.Post_commit_timeout;
                        detail =
                          summarize_post_commit_failure
                            ~tool_names:committed_tools
                            ~kind:Keeper_registry.Post_commit_timeout
                            timeout_err;
                      } )
              in
              post_commit_failure_reason := Some failure_reason;
              Log.Keeper.error
                "%s: turn wall-clock timeout after committed mutating tool call(s) [%s] — treating as integrity failure; evidence recorded for next-turn observation"
                meta.name
                (String.concat ", " committed_tools);
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error reclassified
            end else begin
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error (Oas.Error.Internal msg)
            end)))
      in
      (* Drain correlation_id from the subscription created before the
         turn. Unsubscribe is handled by [unsubscribe_event_bus] in the
         Fun.protect ~finally above, so this path only drains. *)
      (match event_bus_sub, Keeper_event_bus.get () with
       | Some sub, Some _bus ->
         (match Agent_sdk.Event_bus.drain sub with
          | ev :: _ ->
            Keeper_registry.set_last_correlation_id
              ~base_path:config.base_path meta.name
              ev.Agent_sdk.Event_bus.meta.correlation_id
          | [] -> ())
       | _ -> ());
      match run_result with
      | Error err ->
          finalize_trajectory_acc trajectory_acc
            (Trajectory.Failed (Oas.Error.to_string err));
          let e_str = Oas.Error.to_string err in
          let is_transient = is_transient_network_error err in
          let is_server_parse_rejection = is_server_rejected_parse_error err in
          let is_auto_recoverable = is_auto_recoverable_turn_error err in
          let is_ambiguous_partial = is_ambiguous_side_effect_error err in
          Log.Keeper.error
            "%s: keeper cycle FAILED cascade=%s max_context=%d latency=%dms%s error=%s"
            meta.name effective_cascade_name max_context latency_ms
            (if is_ambiguous_partial then
               " (ambiguous partial commit)"
             else if is_server_parse_rejection then
               " (server parse rejection, auto-recoverable)"
             else if is_transient then
               " (transient, cooldown preserved)"
             else "")
            (short_preview e_str);
          let social_state, social_transition_reason =
            Social.derive_failure_state ~meta ~observation
              ~previous_state:previous_social_state ~reason:e_str
          in
          let failure_meta_base =
            match !paused_meta_override with
            | Some paused_meta -> paused_meta
            | None -> meta
          in
          let updated_meta =
            update_metrics_from_failure
              failure_meta_base
              ~latency_ms
              ~observation
              ~reason:e_str
              ~is_transient
              ~social_state
              ~social_transition_reason:
                (Social.transition_reason_to_string social_transition_reason)
              ()
          in
          let updated_meta =
            if is_ambiguous_partial then begin
              (* Ambiguous partial commit must not auto-resume silently.
                 The keeper is paused and an explicit continue gate is
                 raised for the operator. Approving the gate auto-resumes
                 the keeper; rejecting it leaves the keeper paused. *)
              let committed_tools =
                committed_mutating_tools !mutating_tools_committed
              in
              let failure_reason =
                Option.value
                  ~default:
                    (Keeper_registry.Ambiguous_partial_commit {
                      kind = Keeper_registry.Post_commit_failure;
                      detail = e_str;
                    })
                  !post_commit_failure_reason
              in
              Keeper_registry.set_failure_reason ~base_path:config.base_path
                meta.name
                (Some failure_reason);
              let paused_meta =
                sync_keeper_paused_state
                  ~config
                  ~meta:updated_meta
                  ~paused:true
              in
              let approval_id =
                enqueue_reconcile_continue_gate
                  ~config
                  ~meta:paused_meta
                  ~failure_reason
                  ~committed_tools
                  ~error_detail:e_str
              in
              Log.Keeper.warn
                "%s: ambiguous partial commit (tools=[%s], reason=%s); \
                 paused keeper and opened continue gate id=%s"
                meta.name
                (String.concat ", " committed_tools)
                (Keeper_registry.failure_reason_to_string failure_reason)
                approval_id;
              paused_meta
            end else
              updated_meta
          in
          append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms
            ~outcome:(if is_ambiguous_partial then "partial" else "error")
            ~selected_mode:
              (if is_ambiguous_partial
               then "ambiguous_side_effect_error"
               else "error")
            ~social_state
            ~error:e_str ();
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error
                 "write_meta failed after unified turn failure: %s" msg);
          if is_ambiguous_partial then begin
            let failure_reason =
              Option.value
                ~default:
                  (Keeper_registry.Ambiguous_partial_commit {
                    kind = Keeper_registry.Post_commit_failure;
                    detail = e_str;
                  })
                !post_commit_failure_reason
            in
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some failure_reason);
            let committed_tools =
              committed_mutating_tools !mutating_tools_committed
            in
            Log.Keeper.info
              "%s: reconcile-required failure latched as %s after committed tools [%s]"
              meta.name
              (Keeper_registry.failure_reason_to_string failure_reason)
              (String.concat ", " committed_tools)
          end;
          let base_path = config.base_path in
          (* Transient errors (429 rate limit, 503 overloaded, network
             timeout) do not count toward the consecutive failure threshold.
             They are already retried at the turn level with backoff; killing
             the keeper fiber for a transient API blip is an overreaction
             that causes unnecessary restarts and context loss.
             Only persistent errors (auth failure, config error, context
             overflow after compaction) increment the crash counter. *)
          if not is_auto_recoverable then
            Keeper_registry.increment_turn_failures ~base_path meta.name
          else
            Log.Keeper.info
              "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
              meta.name (short_preview e_str);
          let count = Keeper_registry.get_turn_failures ~base_path meta.name in
          let threshold =
            Runtime_params.get Governance_registry.keeper_max_turn_failures
          in
          if count >= threshold then begin
            Log.Keeper.error
              "%s: %d consecutive persistent turn failures (threshold=%d), escalating to supervisor crash path"
              meta.name count threshold;
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some (Keeper_registry.Turn_consecutive_failures count));
            raise Keeper_registry.Keeper_fiber_crash
          end;
          Error err
      | Ok result ->
          finalize_trajectory_acc trajectory_acc Trajectory.Completed;
          let explicit_accountability_claim =
            Social.extract_accountability_claim result
          in
          let result, social_state, social_transition_reason =
            Social.apply_to_result ~meta ~observation
              ~previous_state:previous_social_state result
          in
          let used_model_id =
            Keeper_agent_run.surface_model_used result
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
              ~on_compaction_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Compaction_started)
              ~on_handoff_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Handoff_started)
              ~meta
              ~model:result.model_used
              ~primary_model_max_tokens:max_context
              ~current_turn_overflow_blocker:!current_turn_overflow_blocker
              ~checkpoint:result.checkpoint
          in
          dispatch_post_turn_lifecycle_events
            ~config
            ~keeper_name:meta.name
            lifecycle;
          (* 6. Observe result and update metrics.
             Always update proactive_rt regardless of turn type.
             Previously, scope-only reactive turns (pending_scope but no
             mentions/board) skipped the timestamp update, freezing the
             proactive cooldown timer so the second autonomous turn never
             fired.  See Bug #3 in the root-cause analysis. *)
          let updated_meta =
            update_metrics_from_result lifecycle.updated_meta ~latency_ms
              ~observation
              ~social_state
              ~social_transition_reason:
                (Social.transition_reason_to_string social_transition_reason)
              ~update_proactive_rt:true
              result
          in
          (try
             let channel =
               if observation.pending_mentions <> []
                  || observation.pending_board_events <> []
                  || observation.pending_scope_messages <> []
               then
                 "turn"
               else
                 "scheduled_autonomous"
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
                 "write metrics snapshot failed after keeper cycle: %s"
                 (Printexc.to_string exn));
          (* Emit turn-completed event to Activity Graph for timeline token visibility *)
          (try
            ignore (Activity_graph.emit config
              ~actor:{ kind = "agent"; id = updated_meta.agent_name }
              ~kind:"keeper.turn_completed"
              ~payload:(`Assoc
                ([
                  ("keeper_name", `String updated_meta.name);
                  ("input_tokens", `Int result.usage.input_tokens);
                  ("output_tokens", `Int result.usage.output_tokens);
                  ("cache_creation_tokens", `Int result.usage.cache_creation_input_tokens);
                  ("cache_read_tokens", `Int result.usage.cache_read_input_tokens);
                  ("cost_usd", `Float turn_cost);
                  ("latency_ms", `Int latency_ms);
                  ("model_used", `String (Keeper_agent_run.surface_model_used result));
                  ("work_kind", `String (work_kind_of_selected_mode (selected_mode_of_result result)));
                  ("context_ratio", `Float lifecycle.context_ratio);
                  ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
                ]
                @ (match result.inference_telemetry with
                   | Some t ->
                     (match t.reasoning_tokens with Some n -> [("reasoning_tokens", `Int n)] | None -> [])
                     @ (match t.timings with
                        | Some ti ->
                          (match ti.predicted_per_second with Some v -> [("tokens_per_second", `Float v)] | None -> [])
                        | None -> [])
                   | None -> [])))
              ~tags:["keeper"; "turn"; "metrics"]
              ())
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn
                "activity graph turn_completed emit failed: %s"
                (Printexc.to_string exn));
          broadcast_lifecycle_events ~name:updated_meta.name
            ~turn_generation:lifecycle.turn_generation
            ~compaction:lifecycle.compaction
            ~handoff_json:lifecycle.handoff_json;
          let selected_mode = selected_mode_of_result result in
          append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms ~outcome:"success"
            ~selected_mode
            ~social_state
            ~result:(Some result) ();
          (* Post-turn evidence: deterministic git before/after delta *)
          let turn_evidence =
            try
              Keeper_evidence.capture_turn_evidence
                ~base_path:config.base_path
                ~keeper_name:meta.name
                ~trace_id:(Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id)
                ~turn_number:updated_meta.runtime.usage.total_turns
                ~tool_calls_made:result.tool_calls_made
                ~before_hash:evidence_before_hash
                ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Keeper.warn "post-turn evidence capture failed (unified): %s"
                  (Printexc.to_string exn);
                None
          in
          (match explicit_accountability_claim with
          | Some claim ->
              let trace_id =
                Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id
              in
              let validated_evidence = visible_run_validation result in
              let strong_evidence =
                has_substantive_tool_calls result.tools_used
                || Option.is_some validated_evidence
                ||
                match turn_evidence with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "delta_detected" fields with
                    | Some (`Bool true) -> true
                    | _ -> false)
                | _ -> false
              in
              Keeper_accountability.record_completion_claim config
                ~keeper_name:updated_meta.name
                ~agent_name:updated_meta.agent_name
                ~trace_id
                ~turn_number:updated_meta.runtime.usage.total_turns
                ~subject:claim.subject
                ?task_id:claim.task_id
                ~evidence_refs:claim.evidence_refs
                ~surface:(Social.delivery_surface_to_string social_state.delivery_surface)
                ~strong_evidence
                ~strong_evidence_refs:
                  (accountability_evidence_refs
                     ~trace_id
                     ~turn_number:updated_meta.runtime.usage.total_turns
                     ~result
                     ~validated_evidence
                     ~turn_evidence)
                ()
          | None -> ());
          Log.Keeper.info
            "%s: keeper cycle OK model=%s tokens=%d latency=%dms mode=%s stop=%s"
            updated_meta.name (Keeper_agent_run.surface_model_used result)
            (result.usage.input_tokens + result.usage.output_tokens)
            latency_ms
            selected_mode
            (match result.stop_reason with
             | Oas_worker.Completed -> "completed"
             | Oas_worker.TurnBudgetExhausted { turns_used; limit; _ } ->
                 Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
             | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
                 (match tool_name with
                  | Some tool ->
                      Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                  | None ->
                      Printf.sprintf "mutation_boundary(%d)" turns_used));
          (* 7. Persist updated meta *)
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg -> Log.Keeper.error "write_meta failed after keeper cycle: %s" msg);
          (* 8. Handle stop reason *)
          (match result.stop_reason with
           | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
             (* INFO, not WARN: mirrors MutationBoundaryReached below.
                The keeper made progress and saved a checkpoint; this is
                a normal pause-and-resume signal, not a failure. *)
             Log.Keeper.info
               "keeper:%s turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
               updated_meta.name turns_used limit;
             (* Do NOT increment turn_failures — this is not a crash.
                The keeper made progress and saved a checkpoint.
                Reset failures since the turn itself ran successfully. *)
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.MutationBoundaryReached { tool_name; _ } ->
             Log.Keeper.info
               "keeper:%s mutation boundary reached after %s, checkpoint saved — will resume next cycle"
               updated_meta.name
               (match tool_name with Some tool -> tool | None -> "committed tool");
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.Completed ->
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name);
          Ok updated_meta

let run_unified_turn = run_keeper_cycle
