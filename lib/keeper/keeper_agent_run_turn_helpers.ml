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

let mark_task_link ~keeper ~task_id ~trace_id =
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

[@@@warning "-11"]

let agent_core_stream_event_is_first_token =
  Agent_core.Llm_provider.Streaming.sse_event_is_first_token_signal

let agent_core_stream_event_is_deliverable =
  Agent_core.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal

let sse_event_progress_kind (event : Agent_core.Types.sse_event) =
  match event with
  | Agent_core.Types.MessageStart _ -> Some "sse_message_start"
  | Agent_core.Types.ContentBlockStart _ when agent_core_stream_event_is_deliverable event ->
      Some "sse_tool_block_start"
  | Agent_core.Types.ContentBlockStart _ when agent_core_stream_event_is_first_token event ->
      (* A redacted thinking block arrives whole in its block start; it is
         the only block start that is production. *)
      Some "sse_redacted_thinking"
  | Agent_core.Types.ContentBlockStart _ -> Some "sse_content_block_start"
  | Agent_core.Types.ContentBlockDelta
      { delta = Agent_core.Types.TextDelta _ | Agent_core.Types.TextSnapshot _; _ }
    when agent_core_stream_event_is_deliverable event ->
      Some "sse_text_delta"
  | Agent_core.Types.ContentBlockDelta
      {
        delta =
          ( Agent_core.Types.ThinkingDelta _
          | Agent_core.Types.ReasoningDetailsDelta _ );
        _;
      }
    when agent_core_stream_event_is_first_token event ->
      Some "sse_thinking_delta"
  | Agent_core.Types.ContentBlockDelta
      { delta = Agent_core.Types.InputJsonDelta _ | Agent_core.Types.InputJsonSnapshot _; _ }
    when agent_core_stream_event_is_deliverable event ->
      Some "sse_tool_arg_delta"
  | Agent_core.Types.ContentBlockDelta { delta = Agent_core.Types.MediaDelta _; _ }
    when agent_core_stream_event_is_deliverable event ->
      Some "sse_media_delta"
  | Agent_core.Types.ContentBlockDelta
      { delta = Agent_core.Types.RedactedThinkingSnapshot _; _ }
    when agent_core_stream_event_is_first_token event ->
      Some "sse_redacted_thinking"
  | Agent_core.Types.ContentBlockDelta _ ->
      (* Empty deltas and carrier deltas, such as provider-private reasoning
         signatures, are diagnostic stream evidence only: not text/tool
         progress, not keeper-visible output, and not watchdog progress,
         which the two predicates above keep them out of. *)
      Some "sse_content_delta"
  | Agent_core.Types.ContentBlockStop _ -> Some "sse_content_block_stop"
  | Agent_core.Types.MessageDelta _ -> Some "sse_message_delta"
  | Agent_core.Types.MessageStop -> Some "sse_message_stop"
  | Agent_core.Types.Ping -> None
  | Agent_core.Types.SSEError _ -> Some "sse_error"
  | Agent_core.Types.NDJSONError _ -> Some "ndjson_error"
  | Agent_core.Types.SSEParseFailed _ -> Some "sse_parse_failed"
  | Agent_core.Types.NDJSONParseFailed _ -> Some "ndjson_parse_failed"
  | Agent_core.Types.SSEUnknownEventType _ -> Some "sse_unknown_event_type"
  | Agent_core.Types.SSEUnsupportedPart _ -> Some "sse_unsupported_part"
  | Agent_core.Types.SSEUnsupportedResponse _ -> Some "sse_unsupported_response"
  | Agent_core.Types.StreamIncomplete _ -> Some "sse_stream_incomplete"
  | Agent_core.Types.StreamRepeating _ -> Some "sse_stream_repeating"
  | Agent_core.Types.Connected -> Some "sse_connected"
  | Agent_core.Types.Timeout _ -> Some "sse_timeout"

[@@@warning "+11"]

(* The attempt watchdog asks one question of the stream: is the provider
   still producing? A token of reasoning answers it as a token of text does,
   so both refresh the progress the watchdog measures against, as does a
   tool block opening. Whether what the model produced is deliverable is the
   accept gate's question, asked once the stream has ended: a thinking-only
   response is rejected there as [Thinking_only_no_progress] and the lane
   rotates, so counting reasoning here does not admit a model that only
   thinks. Carrier frames (empty deltas, signatures, block stops, message
   frames, pings) are not production and still refresh nothing.

   Measured 2026-09-14 (system log): 14 attempt terminals on reasoning
   models read "provider call made no progress for 900s" while the 120 s
   inter-line idle budget never fired on any of them, so each stream was
   delivering lines the whole time; a rondo turn's last progress stamp was
   the before_turn hook 901 s before the cut. A live capture of the same
   model streamed 3,940 reasoning deltas and no text in its first 98 s. *)
let sse_event_watchdog_progress_kind event =
  match sse_event_progress_kind event with
  | Some kind
    when agent_core_stream_event_is_first_token event
         || agent_core_stream_event_is_deliverable event -> Some kind
  | Some _ | None -> None

let registry_progress_on_event ~record_turn_progress downstream event =
  Option.iter record_turn_progress (sse_event_watchdog_progress_kind event);
  Option.iter (fun cb -> cb event) downstream


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

let runtime_manifest_context ~keeper_name ~trace_id
    ~keeper_turn_id : Keeper_runtime_manifest.turn_context =
  {
    manifest_keeper_name = keeper_name;
    manifest_trace_id = trace_id;
    manifest_keeper_turn_id = Some keeper_turn_id;
  }

let append_runtime_manifest ~config ~keeper_name ~trace_id
    ~runtime_id ?status ?decision ?keeper_turn_id
    ?agent_core_turn_count ?elapsed_ms ?logical_seq ?checkpoint_path ?receipt_path
    ~site event =
  let decision =
    match keeper_turn_id with
    | None -> decision
    | Some keeper_turn_id ->
      let ctx =
        runtime_manifest_context ~keeper_name ~trace_id
          ~keeper_turn_id
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
                ?agent_core_turn_count ?elapsed_ms ?logical_seq ())
           decision)
  in
  Keeper_runtime_manifest.make ~keeper_name ~trace_id
    ?keeper_turn_id ?agent_core_turn_count ?logical_seq ~event ~runtime_id ?status
    ?decision ?checkpoint_path ?receipt_path ()
  |> Keeper_runtime_manifest.append_best_effort ~site config

(* Teardown runs in its own cancellation context.

   [Keeper_run_tools.cleanup] reaches [Keeper_turn_sandbox_runtime.cleanup],
   which removes the turn's sandbox container with `docker rm -f` through
   [Process_eio]. An Eio call made under an already-cancelled context raises
   [Cancelled] before spawning anything, so without this protection the
   container survives for as long as the server process does (#30590).

   The protected region stays bounded: every command inside runs under the
   Cleanup_rm shell timeout, so [protect] cannot park the caller forever.

   [Cancelled] is reported like any other teardown failure. It used to be
   swallowed by a silent arm, which is why seven containers leaking over a
   37-minute window produced zero log lines and zero counter increments. *)
let run_teardown_protected ~keeper_name ~site f =
  match Eio.Cancel.protect f with
  | () -> ()
  | exception e ->
      let backtrace = Printexc.get_backtrace () in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DispatchEventFailures)
        ~labels:[ "keeper", keeper_name; "site", site ]
        ();
      Log.Keeper.warn
        "%s: keeper %s teardown raised: %s%s"
        keeper_name
        site
        (Printexc.to_string e)
        (if String.equal backtrace "" then "" else "\n" ^ backtrace)

let cleanup_agent_setup ~keeper_name (setup : Keeper_run_tools.agent_setup) =
  run_teardown_protected ~keeper_name ~site:"tool_cleanup" (fun () ->
    setup.Keeper_run_tools.cleanup ())

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
  ?agent_core_turn_count:int ->
  ?checkpoint_path:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

let make_append_manifest
    ~config
    ~keeper_name
    ~trace_id
    ~runtime_id
    ~(turn_start : Mtime.t)
    ~(seq_ref : int Atomic.t)
  : append_manifest_fn
  =
  fun ?elapsed_ms ?logical_seq ?status ?decision ?keeper_turn_id ->
  fun ?agent_core_turn_count ?checkpoint_path ~site event ->
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
    ~trace_id
    ~runtime_id
    ?status ?decision ?keeper_turn_id ?agent_core_turn_count
    ?elapsed_ms ?logical_seq
    ?checkpoint_path
    ~site
    event

(* RFC librarian-lifecycle 4.6. A reader learns that the atoms of a trace are
   numbered from zero again from a restart line, and it may act on the line as
   soon as it sees it. So the line must not be ahead of the restart.

   A turn that starts from no atom and knows the saved history holds none --
   it loaded an empty one, or the store has none -- says so at once: nothing
   can be saved before the line, whichever save inside [run_turn] comes first
   (a stage save, the finalize save, the approval-input admission, the official
   client host's reject flush).

   A turn that starts from no atom because its checkpoint could not be loaded
   has not seen the saved history, which may still hold atoms. The restart
   happens only if a save of this turn is accepted and replaces it, so the
   line follows the first accepted save. When that first accepted save is the
   finalize save, the turn's own [Fresh_history] line is that line. *)
type restart_notice =
  | No_restart_notice
  | Notice_at_turn_start
  | Notice_after_first_save

let restart_notice
      (history_at_start : Keeper_turn_boundaries.history_at_start)
      (saved_history : Keeper_run_context.saved_history)
  =
  match history_at_start, saved_history with
  | ( Keeper_turn_boundaries.Continued_history
    , ( Keeper_run_context.Saved_history_loaded
      | Keeper_run_context.Saved_history_absent
      | Keeper_run_context.Saved_history_unread ) ) -> No_restart_notice
  | ( Keeper_turn_boundaries.Fresh_history
    , (Keeper_run_context.Saved_history_loaded | Keeper_run_context.Saved_history_absent) )
    -> Notice_at_turn_start
  | Keeper_turn_boundaries.Fresh_history, Keeper_run_context.Saved_history_unread ->
    Notice_after_first_save
;;

type restart_site =
  | At_turn_start
  | After_first_save

let restart_site_label = function
  | At_turn_start -> "turn_start"
  | After_first_save -> "first_save"
;;

(* A line that cannot be written does not fail the turn: it is logged and
   counted. Only a cancellation escapes. *)
let record_history_restart ~(config : Workspace.config) ~keeper_name ~trace_id site =
  let not_recorded detail =
    Log.Keeper.error
      ~keeper_name
      "history restart not recorded site=%s: %s"
      (restart_site_label site)
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnBoundaryFailures)
      ~labels:[ "keeper", keeper_name; "site", restart_site_label site ]
      ()
  in
  let record : Keeper_turn_boundaries.record =
    { recorded_at = Time_compat.now ()
    ; event = Keeper_turn_boundaries.History_restarted { trace_id }
    }
  in
  match
    Keeper_turn_boundaries.append
      ~keepers_dir:
        (Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
      ~keeper_id:keeper_name
      record
  with
  | Ok () -> ()
  | Error error -> not_recorded (Keeper_turn_boundaries.append_error_to_string error)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> not_recorded (Printexc.to_string exn)
;;

(* A turn owing [Notice_after_first_save] writes no restart line of its own
   when no stage save was accepted before the finalize save: its
   [Fresh_history] end line is the restart line. A reader gets the same
   answer either way, so nothing is missing -- but the branch leaves no trace
   of itself, and someone reading the log later stops at "why has this turn no
   restart line". Counting it answers that, and a zero says the branch does
   not run. *)
let note_restart_line_stood_in ~keeper_name =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HistoryRestartStoodIn)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let turn_progress_callbacks ~config ~keeper_name ~downstream ~turn_id =
  Keeper_turn_preview.reset ~keeper_name ~now:(Time_compat.now ());
  let record_turn_progress event_kind =
    Keeper_registry.record_turn_progress
      ~base_path:config.Workspace.base_path
      keeper_name
      ~event_kind
  in
  (* Keeper tool execution and typed recovery judgment are separate provider
     lease phases. This is a Keeper lifecycle invariant, not an operator
     tuning knob: AGENT_CORE releases before tools/judgment and reacquires only for
     the next main-model turn. *)
  let yield_on_tool = true in
  (* SSOT-DRIFT-REMEDIATION: Streaming⇄Awaiting_tool_result FSM transitions
     are now emitted from the turn-scoped AGENT_CORE Event_bus observation in
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
  let on_event = Some (fun event ->
    Keeper_turn_preview.note_stream ~keeper_name ~now:(Time_compat.now ()) event;
    registry_progress_on_event ~record_turn_progress downstream event) in
  (record_turn_progress, yield_on_tool, on_yield, on_resume, on_event)
