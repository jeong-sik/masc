(* Idempotency cache for link_task_execution_artifacts (PR #14564 review).
   The link call writes the backlog file and emits a Task.Linked activity
   event each invocation. Keying on (keeper_name, task_id, trace_id) means
   we only call link once per (task, trace) pair instead of once per turn.

   trace_id rotates on every keeper run, and task_id grows over the
   lifetime of a long-lived process, so the entry count is unbounded
   in principle. A bounded FIFO eviction keeps the table at a fixed
   ceiling. Losing the oldest entry only forces one extra link call,
   which costs one backlog write but never breaks correctness. *)

module Link_task_cache_key = struct
  type t = string * string * string
  let compare = compare
end

module Link_task_cache_map = Map.Make (Link_task_cache_key)

type link_task_cache_state =
  { entries : unit Link_task_cache_map.t
  ; order : Link_task_cache_key.t list
  ; size : int
  }

let link_task_cache_max_entries = 4096

let link_task_cache_state =
  Atomic.make
    { entries = Link_task_cache_map.empty; order = []; size = 0 }

let evict_oldest state =
  match List.rev state.order with
  | [] -> state
  | oldest :: rest ->
    { entries = Link_task_cache_map.remove oldest state.entries
    ; order = List.rev rest
    ; size = state.size - 1
    }

let rec mark_task_link ~keeper ~task_id ~trace_id =
  let key = (keeper, task_id, trace_id) in
  let rec loop () =
    let state = Atomic.get link_task_cache_state in
    if Link_task_cache_map.mem key state.entries then
      ()
    else
      let state =
        if state.size >= link_task_cache_max_entries
        then evict_oldest state
        else state
      in
      let new_state =
        { entries = Link_task_cache_map.add key () state.entries
        ; order = key :: state.order
        ; size = state.size + 1
        }
      in
      if not (Atomic.compare_and_set link_task_cache_state state new_state)
      then loop ()
  in
  loop ()

let task_link_already_recorded ~keeper ~task_id ~trace_id =
  let key = (keeper, task_id, trace_id) in
  Link_task_cache_map.mem key (Atomic.get link_task_cache_state).entries

let per_provider_timeout_for_turn
    ?oas_timeout_s
    ?(oas_timeout_is_explicit = true)
    ~(timeout_s : float)
    () =
  match (oas_timeout_s, oas_timeout_is_explicit) with
  | (Some _ as explicit_timeout), true -> explicit_timeout
  | _, _ -> Some timeout_s

[@@@warning "-11"]

let sdk_stream_event_is_first_token =
  Agent_sdk.Llm_provider.Streaming.sse_event_is_first_token_signal

let sdk_stream_event_is_deliverable =
  Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal

let sse_event_progress_kind (event : Agent_sdk.Types.sse_event) =
  match event with
  | Agent_sdk.Types.MessageStart _ -> Some "sse_message_start"
  | Agent_sdk.Types.ContentBlockStart _ when sdk_stream_event_is_deliverable event ->
      Some "sse_tool_block_start"
  | Agent_sdk.Types.ContentBlockStart _ -> Some "sse_content_block_start"
  | Agent_sdk.Types.ContentBlockDelta { delta = Agent_sdk.Types.TextDelta _; _ }
    when sdk_stream_event_is_deliverable event ->
      Some "sse_text_delta"
  | Agent_sdk.Types.ContentBlockDelta
      {
        delta =
          ( Agent_sdk.Types.ThinkingDelta _
          | Agent_sdk.Types.ReasoningDetailsDelta _ );
        _;
      }
    when sdk_stream_event_is_first_token event ->
      Some "sse_thinking_delta"
  | Agent_sdk.Types.ContentBlockDelta
      { delta = Agent_sdk.Types.InputJsonDelta _ | Agent_sdk.Types.InputJsonSnapshot _; _ }
    when sdk_stream_event_is_deliverable event ->
      Some "sse_tool_arg_delta"
  | Agent_sdk.Types.ContentBlockDelta { delta = Agent_sdk.Types.MediaDelta _; _ }
    when sdk_stream_event_is_deliverable event ->
      Some "sse_media_delta"
  | Agent_sdk.Types.ContentBlockDelta _ ->
      (* Future OAS carrier deltas, such as provider-private reasoning signatures,
         are diagnostic stream evidence only. They must not be promoted to
         text/tool progress, keeper-visible output, or watchdog progress. *)
      Some "sse_content_delta"
  | Agent_sdk.Types.ContentBlockStop _ -> Some "sse_content_block_stop"
  | Agent_sdk.Types.MessageDelta _ -> Some "sse_message_delta"
  | Agent_sdk.Types.MessageStop -> Some "sse_message_stop"
  | Agent_sdk.Types.Ping -> None
  | Agent_sdk.Types.SSEError _ -> Some "sse_error"
  | Agent_sdk.Types.SSEParseFailed _ -> Some "sse_parse_failed"
  | Agent_sdk.Types.SSEUnknownEventType _ -> Some "sse_unknown_event_type"
  | Agent_sdk.Types.StreamIncomplete _ -> Some "sse_stream_incomplete"
  | Agent_sdk.Types.Connected -> Some "sse_connected"
  | Agent_sdk.Types.Timeout _ -> Some "sse_timeout"

[@@@warning "+11"]

let sse_event_watchdog_progress_kind event =
  match sse_event_progress_kind event with
  | Some kind when sdk_stream_event_is_deliverable event -> Some kind
  | _ -> None

let registry_progress_on_event ~record_turn_progress downstream event =
  Option.iter record_turn_progress (sse_event_watchdog_progress_kind event);
  Option.iter (fun cb -> cb event) downstream


let completion_contract_result_for_progress_evidence
    ~(had_owned_active_task_at_turn_start : bool)
    ~(actual_keeper_tool_names : string list) :
    Keeper_execution_receipt.completion_contract_result =
  let class_of name = Keeper_tool_progress.classify_tool_progress name in
  let classes = List.map class_of actual_keeper_tool_names in
  let has_class wanted = List.exists (( = ) wanted) classes in
  let all_class wanted = classes <> [] && List.for_all (( = ) wanted) classes in
  if actual_keeper_tool_names = [] then
    Keeper_execution_receipt.Contract_satisfied_completion
  else if
    all_class Keeper_tool_progress.Claim_context
    && had_owned_active_task_at_turn_start
  then Keeper_execution_receipt.Contract_claim_only_after_owned_task
  else if
    has_class Keeper_tool_progress.Claim_context
    && not had_owned_active_task_at_turn_start
  then Keeper_execution_receipt.Contract_satisfied_execution
  else if all_class Keeper_tool_progress.Passive_status then
    Keeper_execution_receipt.Contract_passive_only
  else if has_class Keeper_tool_progress.Completion then
    Keeper_execution_receipt.Contract_satisfied_completion
  else if has_class Keeper_tool_progress.Execution then
    Keeper_execution_receipt.Contract_satisfied_execution
  else Keeper_execution_receipt.Contract_needs_execution_progress

let emit_turn_end_safely ~keeper_name () =
  try Masc_runtime_events.emit_turn_end () with
  | Eio.Cancel.Cancelled _ -> ()
  | e ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DispatchEventFailures)
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
    ~generation ~runtime_id ?status ?decision ?keeper_turn_id
    ?oas_turn_count ?elapsed_ms ?logical_seq ?checkpoint_path ?receipt_path
    ?compaction_source ~site event =
  let decision =
    match keeper_turn_id with
    | None -> decision
    | Some keeper_turn_id ->
      let ctx =
        runtime_manifest_context ~keeper_name ~agent_name ~trace_id
          ~generation ~keeper_turn_id
      in
      let decision =
        match decision with
        | Some value -> value
        | None -> `Assoc []
      in
      Some
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs:
             (Keeper_runtime_manifest.clock_refs_for_context ctx ~event
                ?oas_turn_count ?elapsed_ms ?logical_seq ?compaction_source ())
           decision)
  in
  Keeper_runtime_manifest.make ~keeper_name ~agent_name ~trace_id ~generation
    ?keeper_turn_id ?oas_turn_count ?logical_seq ~event ~runtime_id ?status
    ?decision ?checkpoint_path ?receipt_path ()
  |> Keeper_runtime_manifest.append_best_effort ~site config

let cleanup_agent_setup ~keeper_name (setup : Keeper_run_tools.agent_setup) =
  try setup.Keeper_run_tools.cleanup () with
  | Eio.Cancel.Cancelled _ -> ()
  | e ->
      let backtrace = Printexc.get_backtrace () in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DispatchEventFailures)
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

type append_manifest_fn =
  ?elapsed_ms:int ->
  ?logical_seq:int ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?compaction_source:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

let make_append_manifest
    ~config
    ~keeper_name
    ~agent_name
    ~trace_id
    ~generation
    ~runtime_id
    ~(turn_start : Mtime.t)
    ~(seq_ref : int Atomic.t)
  : append_manifest_fn
  =
  fun ?elapsed_ms ?logical_seq ?status ?decision ?keeper_turn_id ->
  fun ?oas_turn_count ?checkpoint_path ?compaction_source ~site event ->
  let elapsed_ms =
    match elapsed_ms with
    | Some _ -> elapsed_ms
    | None ->
      let ns =
        Mtime.Span.to_uint64_ns (Mtime.span turn_start (Mtime_clock.now ()))
      in
      Some (Int64.to_int (Int64.div ns 1_000_000L))
  in
  let logical_seq =
    match logical_seq with
    | Some _ -> logical_seq
    | None ->
      let n = Atomic.fetch_and_add seq_ref 1 in
      Some (n + 1)
  in
  append_runtime_manifest
    ~config
    ~keeper_name
    ~agent_name
    ~trace_id
    ~generation
    ~runtime_id
    ?status ?decision ?keeper_turn_id ?oas_turn_count
    ?elapsed_ms ?logical_seq
    ?checkpoint_path ?compaction_source
    ~site
    event

let turn_progress_callbacks ~config ~keeper_name ~downstream ~turn_id =
  let record_turn_progress event_kind =
    Keeper_registry.record_turn_progress
      ~base_path:config.Workspace.base_path
      keeper_name
      ~event_kind
  in
  (* Keeper tool execution and typed recovery judgment are separate provider
     lease phases. This is a Keeper lifecycle invariant, not an operator
     tuning knob: OAS releases before tools/judgment and reacquires only for
     the next main-model turn. *)
  let yield_on_tool = true in
  (* SSOT-DRIFT-REMEDIATION: Streaming⇄Awaiting_tool_result FSM transitions
     are now emitted from the turn-scoped OAS Event_bus observation in
     [Keeper_unified_turn_event_bus], so they appear unconditionally even
     independently of these lease callbacks. The callbacks below record the
     mandatory Keeper provider-lease transition. *)
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
