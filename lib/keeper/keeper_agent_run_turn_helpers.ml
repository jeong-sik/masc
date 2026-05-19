(* Idempotency cache for link_task_execution_artifacts (PR #14564 review).
   The link call writes the backlog file and emits a Task.Linked activity
   event each invocation. Keying on (keeper_name, task_id, trace_id) means
   we only call link once per (task, trace) pair instead of once per turn.

   trace_id rotates on every keeper run, and task_id grows over the
   lifetime of a long-lived process, so the entry count is unbounded
   in principle. A bounded FIFO eviction keeps the table at a fixed
   ceiling. Losing the oldest entry only forces one extra link call,
   which costs one backlog write but never breaks correctness. *)

let link_task_cache_max_entries = 4096

let link_task_cache : (string * string * string, unit) Hashtbl.t =
  Hashtbl.create link_task_cache_max_entries

(* FIFO order so we know which entry to evict when the table is full. *)
let link_task_cache_order : (string * string * string) Queue.t = Queue.create ()
let link_task_cache_mutex = Stdlib.Mutex.create ()

let evict_oldest_locked () =
  match Queue.take_opt link_task_cache_order with
  | None -> ()
  | Some key -> Hashtbl.remove link_task_cache key

let mark_task_link ~keeper ~task_id ~trace_id =
  let key = (keeper, task_id, trace_id) in
  Stdlib.Mutex.protect link_task_cache_mutex (fun () ->
    if Hashtbl.mem link_task_cache key then
      ()
    else (
      while Hashtbl.length link_task_cache >= link_task_cache_max_entries do
        evict_oldest_locked ()
      done;
      Hashtbl.add link_task_cache key ();
      Queue.add key link_task_cache_order))

let task_link_already_recorded ~keeper ~task_id ~trace_id =
  Stdlib.Mutex.protect link_task_cache_mutex (fun () ->
    Hashtbl.mem link_task_cache (keeper, task_id, trace_id))

let per_provider_timeout_for_turn
    ~(meta : Keeper_types.keeper_meta)
    ?oas_timeout_s
    ?(oas_timeout_is_explicit = true)
    ~(timeout_s : float)
    () =
  match (oas_timeout_s, oas_timeout_is_explicit) with
  | (Some _ as explicit_timeout), true -> explicit_timeout
  | _, _ -> (
      match meta.per_provider_timeout_s with
      | Some configured -> Some (Float.min configured timeout_s)
      | None -> Some timeout_s)

let sse_event_progress_kind (event : Agent_sdk.Types.sse_event) =
  match event with
  | Agent_sdk.Types.MessageStart _ -> Some "sse_message_start"
  | Agent_sdk.Types.ContentBlockStart { tool_name = Some _; _ } ->
      Some "sse_tool_block_start"
  | Agent_sdk.Types.ContentBlockStart _ -> Some "sse_content_block_start"
  | Agent_sdk.Types.ContentBlockDelta { delta = Agent_sdk.Types.TextDelta _; _ } ->
      Some "sse_text_delta"
  | Agent_sdk.Types.ContentBlockDelta { delta = Agent_sdk.Types.ThinkingDelta _; _ } ->
      Some "sse_thinking_delta"
  | Agent_sdk.Types.ContentBlockDelta { delta = Agent_sdk.Types.InputJsonDelta _; _ } ->
      Some "sse_tool_arg_delta"
  | Agent_sdk.Types.ContentBlockStop _ -> Some "sse_content_block_stop"
  | Agent_sdk.Types.MessageDelta _ -> Some "sse_message_delta"
  | Agent_sdk.Types.MessageStop -> Some "sse_message_stop"
  | Agent_sdk.Types.Ping -> None
  | Agent_sdk.Types.SSEError _ -> Some "sse_error"
  | Agent_sdk.Types.SSEParseFailed _ -> Some "sse_parse_failed"
  | Agent_sdk.Types.SSEUnknownEventType _ -> Some "sse_unknown_event_type"

let registry_progress_on_event ~record_turn_progress downstream event =
  Option.iter record_turn_progress (sse_event_progress_kind event);
  Option.iter (fun cb -> cb event) downstream

let select_cdal_proof ~result_proof ~captured_proof =
  match result_proof with
  | Some _ -> result_proof
  | None -> captured_proof

let should_require_provider_tool_choice_support
    ~initial_tool_requirement
    ~actionable_observation_requires_tool_support =
  initial_tool_requirement = Keeper_agent_tool_surface.Required
  || actionable_observation_requires_tool_support

let tool_contract_result_for_observed_tools
    ~(required_tool_names : string list)
    ~(missing_visible_required : string list)
    ~(had_owned_active_task_at_turn_start : bool)
    ~(actual_keeper_tool_names : string list) :
    Keeper_execution_receipt.tool_contract_result =
  let class_of name = Keeper_tool_disclosure.classify_tool_progress name in
  let classes = List.map class_of actual_keeper_tool_names in
  let has_class wanted = List.exists (( = ) wanted) classes in
  let all_class wanted = classes <> [] && List.for_all (( = ) wanted) classes in
  let all_required_used =
    List.for_all
      (fun name -> List.mem name actual_keeper_tool_names)
      required_tool_names
  in
  if missing_visible_required <> [] then
    Keeper_execution_receipt.Contract_tool_surface_mismatch
  else if required_tool_names <> [] && not all_required_used then
    if actual_keeper_tool_names = [] then
      Keeper_execution_receipt.Contract_missing_required_tool_use
    else if
      all_class Keeper_tool_disclosure.Claim_context
      && had_owned_active_task_at_turn_start
    then Keeper_execution_receipt.Contract_claim_only_after_owned_task
    else if all_class Keeper_tool_disclosure.Passive_status then
      Keeper_execution_receipt.Contract_passive_only
    else Keeper_execution_receipt.Contract_missing_required_tool_use
  else if actual_keeper_tool_names = [] then
    Keeper_execution_receipt.Contract_satisfied_completion
  else if
    all_class Keeper_tool_disclosure.Claim_context
    && had_owned_active_task_at_turn_start
  then Keeper_execution_receipt.Contract_claim_only_after_owned_task
  else if
    has_class Keeper_tool_disclosure.Claim_context
    && not had_owned_active_task_at_turn_start
  then Keeper_execution_receipt.Contract_satisfied_execution
  else if all_class Keeper_tool_disclosure.Passive_status then
    Keeper_execution_receipt.Contract_passive_only
  else if has_class Keeper_tool_disclosure.Completion then
    Keeper_execution_receipt.Contract_satisfied_completion
  else if has_class Keeper_tool_disclosure.Execution then
    Keeper_execution_receipt.Contract_satisfied_execution
  else Keeper_execution_receipt.Contract_needs_execution_progress

let emit_turn_end_safely ~keeper_name () =
  try Masc_runtime_events.emit_turn_end () with
  | Eio.Cancel.Cancelled _ -> ()
  | e ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_dispatch_event_failures
        ~labels:[ "keeper", keeper_name; "site", "emit_turn_end" ]
        ();
      Log.Keeper.warn
        "%s: emit_turn_end in finally raised: %s"
        keeper_name
        (Printexc.to_string e)

let digest_text text = Digest.to_hex (Digest.string text)

let digest_message_texts_as_joined messages =
  let module Hash = Digestif.MD5 in
  let rec loop ctx = function
    | [] -> ctx
    | [ message ] -> Hash.feed_string ctx (Agent_sdk.Types.text_of_message message)
    | message :: rest ->
        let ctx = Hash.feed_string ctx (Agent_sdk.Types.text_of_message message) in
        loop (Hash.feed_string ctx "\n") rest
  in
  Hash.(to_hex (get (loop empty messages)))

let runtime_manifest_context ~keeper_name ~agent_name ~trace_id ~generation
    ~keeper_turn_id : Keeper_runtime_manifest.turn_context =
  {
    manifest_keeper_name = keeper_name;
    manifest_agent_name = Some agent_name;
    manifest_trace_id = trace_id;
    manifest_generation = Some generation;
    manifest_keeper_turn_id = Some keeper_turn_id;
  }

let append_runtime_manifest ~config ~keeper_name ~agent_name ~trace_id
    ~generation ~cascade_name ?status ?decision ?keeper_turn_id
    ?oas_turn_count ?checkpoint_path ?receipt_path ~site event =
  Keeper_runtime_manifest.make ~keeper_name ~agent_name ~trace_id ~generation
    ?keeper_turn_id ?oas_turn_count ~event ~cascade_name ?status ?decision
    ?checkpoint_path ?receipt_path ()
  |> Keeper_runtime_manifest.append_best_effort ~site config

let cleanup_agent_setup ~keeper_name (setup : Keeper_run_tools.agent_setup) =
  try setup.Keeper_run_tools.cleanup () with
  | Eio.Cancel.Cancelled _ -> ()
  | e ->
      let backtrace = Printexc.get_backtrace () in
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_dispatch_event_failures
        ~labels:[ "keeper", keeper_name; "site", "tool_cleanup" ]
        ();
      Log.Keeper.warn
        "%s: keeper tool bundle cleanup raised: %s%s"
        keeper_name
        (Printexc.to_string e)
        (if String.equal backtrace "" then "" else "\n" ^ backtrace)

let run_with_setup_cleanup ~cleanup f =
  match f () with
  | result ->
      cleanup ();
      result
  | exception e ->
      let backtrace = Printexc.get_raw_backtrace () in
      cleanup ();
      Printexc.raise_with_backtrace e backtrace

let turn_progress_callbacks ~config ~keeper_name ~downstream =
  let record_turn_progress event_kind =
    Keeper_registry.record_turn_progress
      ~base_path:config.Coord.base_path
      keeper_name
      ~event_kind
  in
  let yield_on_tool = Env_config.Slot.yield_enabled () in
  let on_yield =
    if yield_on_tool then
      Some
        (fun () ->
          record_turn_progress "slot_yield";
          Log.Misc.debug "keeper %s: slot yielded (tool execution)" keeper_name)
    else None
  in
  let on_resume =
    if yield_on_tool then
      Some
        (fun () ->
          record_turn_progress "slot_resume";
          Log.Misc.debug "keeper %s: slot resumed (next LLM turn)" keeper_name)
    else None
  in
  let on_event = Some (registry_progress_on_event ~record_turn_progress downstream) in
  (record_turn_progress, yield_on_tool, on_yield, on_resume, on_event)

let record_wake_payload_if_enabled ~meta ~trace_id ~start_turn_count ~max_context
    ~pre_dispatch_compacted ~turn_system_prompt ~tools ~history_messages ~user_message =
  if Env_config_keeper.KeeperTelemetry.payload_telemetry_enabled () then
    try
      let sizes =
        Keeper_wake_telemetry.compute_sizes
          ~system_prompt:turn_system_prompt
          ~tools
          ~history_messages
          ~user_message
      in
      let model_id =
        match Keeper_model_labels.configured_model_labels_of_meta meta with
        | m :: _ -> m
        | [] -> "auto"
      in
      let _event : Dashboard_harness_health.wake_payload_event =
        Dashboard_harness_health.record_wake_payload
          ~keeper_name:meta.name
          ~trace_id
          ~turn_index:start_turn_count
          ~model_id
          ~context_window:max_context
          ~approx_body_bytes:sizes.approx_body_bytes
          ~system_prompt_bytes:sizes.system_prompt_bytes
          ~tool_defs_bytes:sizes.tool_defs_bytes
          ~messages_bytes:sizes.messages_bytes
          ~message_count:sizes.message_count
          ~role_counts:sizes.role_counts
          ~tool_count:sizes.tool_count
          ~has_compact_happened:pre_dispatch_compacted
      in
      ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Harness.warn
          "[wake_payload] telemetry failed keeper=%s: %s"
          meta.name
          (Printexc.to_string exn)
