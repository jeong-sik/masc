(** Keeper_turn_driver_try_provider — extracted [try_provider] closure.

    RFC-0051 PR-3a: closure-to-toplevel-fn conversion with explicit ctx record.
    The [try_provider] closure was defined inside [Keeper_turn_driver.run_named]
    and captured ~51 variables from the enclosing scope. This module makes
    that boundary explicit via a record, so the compiler verifies every
    dependency and the function body is independently testable.

    @since RFC-0051 PR-3a *)

open Result.Syntax

(** A reading of the keeper's live in-turn progress signal (#28417).

    Mirrors the two fields of [Keeper_registry_types.turn_observation] the
    stall decision needs. Kept as its own record so this module does not
    depend on [Keeper_registry]: the caller supplies the reading, this module
    decides. *)
type provider_progress_sample =
  { last_progress_at : float
        (** Unix timestamp of the most recent in-turn progress signal
            (registry transitions, Agent Core streaming events, completed
            tool calls). *)
  ; active_tool_count : int
        (** Tools issued but not yet completed. A tool that runs for minutes
            refreshes no progress signal while it runs, so a non-zero count
            means "working", not "stalled" -- the exclusion
            [Keeper_registry_types]' [active_tool_count] doc comment has
            described since RFC-0197 without any code ever reading it. *)
  ; awaiting_approval : bool
        (** Whether a tool call from this keeper is parked waiting for an
            operator to answer.

            A held call refreshes no progress signal and is not counted in
            [active_tool_count]: the approval gate runs at [pre_tool_use],
            and [ToolCalled] -- what raises that count -- is published inside
            [execute_admitted], which the gate runs before. So a keeper
            waiting on a person looked exactly like a provider that had
            stopped answering, and with a deadline configured under the
            180s approval bound the watchdog cancelled the attempt and
            reported "provider call made no progress". The provider had
            answered; nobody had. *)
  }

(** Explicit context record for the extracted [try_provider] function.

    Each field corresponds to a variable captured by the original closure.
    Fields are grouped by role: runtime identity, agent config, transport,
    session/checkpoint, Eio primitives, callbacks, and event bus. *)
type try_provider_ctx =
  { (* Runtime identity *)
    runtime_id : string
  ; error_runtime_id : string
  ; max_request_body_bytes : int option
  ; (* The window [bounded_model_input_projection] cuts the history to, in
       tokens (RFC keeper-context-window-in-tokens). Declared by the turn
       driver from [turn.context_window_tokens];
       [run_try_provider_with_context_overflow_shrink] halves it on a typed
       provider context overflow and retries the SAME candidate, and the
       window it runs at names its source. [max_request_body_bytes] is
       independent of it: it judges the serialized request and reports the
       real declared cap to wire-error diagnostics
       ([observe_request_wire_error], [pre_dispatch_serialization_observer]),
       and it never shapes the window. *)
    model_input_window : Keeper_context_window.t
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; (* Agent config — fields passed through the runtime candidate boundary. *)
    goal : string
  ; goal_blocks : Agent_core.Types.content_block list option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; initial_messages : Agent_core.Types.message list
  ; model_input_projection : Agent_core.Agent.model_input_projection option
  ; recovery_view : Keeper_recovery_transmission.t option
  ; stream_idle_timeout_s : float
    (* Bound on the silent gap between two streamed lines. It re-arms after
       every line, so it detects a stalled stream, not a long turn. The keeper
       always has one: the operator's value or the RFC-0345 floor. AGENT_CORE
       reads it as an option; that [Some] is built once, where this record is
       projected onto [Runtime_agent.config]. *)
  ; first_event_timeout_s : float
    (* Bound on the silent wait for the FIRST streaming provider event
       (TTFT/prefill), distinct from [stream_idle_timeout_s] which arms only
       after that event (RFC-AC-037). Always set, for the same reason. *)
  ; body_timeout_s : float option
  ; (* #27349, axis changed by #28417: the ceiling for THIS provider call
       attempt. Distinct from [stream_idle_timeout_s] (streaming inter-line
       gap) and [body_timeout_s] (non-streaming body read only): both of
       those are AGENT_CORE-internal and observe the transport only, which is
       why they left the non-streaming and pre-first-token (Queue)
       stalls of #27355 unprotected.

       #27349 measured this against total elapsed wall-clock. Elapsed cannot
       separate "a turn that stopped" from "a turn that is taking a while",
       and on 2026-08-12 the same 900s value did both at once: it correctly
       rotated 4 wedged attempts (65 minutes with zero trajectory
       events) and killed a healthy Keeper attempt 6 seconds after a
       successful tool call (30+ tool calls inside the window, longest
       progress gap 120s). #28417 moves the measurement onto the progress
       signal, which is the distinction #27355's own observation side always
       documented -- see the OTel help text emitted for
       [InFlightElapsedSeconds]: "a supervising consumer judges staleness
       against progress, not against this value alone."

       Always set: the operator's value or the resolved layer's failsafe
       floor. There is no "off" (an attempt this could not end would be one
       only an operator could end). *)
    provider_call_deadline_sec : float
  ; (* #28417: reads the keeper's live turn progress signal. Injected as a
       callback instead of calling [Keeper_registry] from here so the stall
       decision stays a pure function of its inputs (unit-testable with no
       registry on disk) and this module keeps its current dependency set.

       [None] disables progress-awareness and the deadline degrades to the
       pre-#28417 elapsed ceiling. That is the conservative direction: it can
       fire early on a healthy turn, never late on a wedged one. *)
    provider_progress_probe : (unit -> provider_progress_sample option) option
  ; (* Reads whether a person's chat operation is queued behind this turn.
       Injected (not read from [Keeper_registry] here) so the preemption verdict
       stays a pure function of its inputs. Present only on the autonomous lane;
       [None] disables first-token-wait preemption and the attempt keeps the
       full first-event/idle bounds (RFC-0441 pre-first-token gap). *)
    person_queued_probe : (unit -> bool) option
  ; temperature : float option
  ; accept : Agent_core.Types.api_response -> bool
  ; hooks : Agent_core.Hooks.hooks option
  (* Installed on the config below when present: its pre_tool_use composes
     over [hooks] as the outer set, and its callback is what AGENT_CORE calls
     to settle an ElicitToolApproval. Absent means no call is held. *)
  ; approval_gate : Keeper_tool_approval_gate.t option
  ; raw_trace : Agent_core.Raw_trace.t option
  ; trace_link : (string * string) option
  ; (* Transport *)
    transport_resolved : Masc_grpc_transport.t
  ; (* Session / checkpoint *)
    checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; checkpoint_sink : Agent_core.Agent.checkpoint_sink option
  ; checkpoint_stage_observed : bool Atomic.t
  ; context_injector : Agent_core.Hooks.context_injector option
  ; context : Agent_core.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; cooperative_yield_probe : Runtime_agent.cooperative_yield_probe option
  ; agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; (* Eio concurrency *)
    sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; (* Callbacks *)
    on_event : (Agent_core.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_core.Agent.t option ref option
  ; on_runtime_observation :
      (Runtime_observation.runtime_observation -> unit) option
  ; on_request_wire_observation :
      (runtime_id:string ->
       max_request_body_bytes:int option ->
       body_bytes:int ->
       serialized:Llm_provider.Request_wire_observer.observation option ->
       unit)
        option
  ; on_model_input_window_observation :
      (measurement:Turn_record.model_input_measurement
       -> Runtime_model_input_tail_window.window_observation
       -> unit)
        option
  ; (* Event bus *)
    event_bus : Agent_core.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

let emit_runtime_manifest
      (ctx : try_provider_ctx)
      ?status
      ?decision
      event
  =
  match ctx.runtime_manifest_context, ctx.runtime_manifest_append with
  | Some manifest_ctx, Some append ->
    let decision =
      (* RFC-0206: the runtime-engine manifest base fields are gone; the
         decision payload carries only its own fields now. *)
      match decision with
      | None -> Some (`Assoc [])
      | Some (`Assoc _) as d -> d
      | Some other -> Some (`Assoc [ ("decision", other) ])
    in
    ctx.seq_ref := !(ctx.seq_ref) + 1;
    let elapsed_ms =
      let ns =
        Mtime.Span.to_uint64_ns
          (Mtime.span ctx.turn_start (Mtime_clock.now ()))
      in
      Some (Int64.to_int (Int64.div ns 1_000_000L))
    in
    let decision =
      let decision =
        match decision with
        | Some value -> value
        | None -> `Assoc []
      in
      Some
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs:
             (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx ~event
                ?elapsed_ms ~logical_seq:!(ctx.seq_ref) ())
           decision)
    in
    Keeper_runtime_manifest.make_for_context manifest_ctx ~event
      ~runtime_id:ctx.runtime_id ?logical_seq:(Some !(ctx.seq_ref))
      ?status ?decision ()
    |> append
  | _ -> ()

(* #27320: records a same-runtime context-overflow shrink retry on the
   existing per-attempt manifest channel (the same [Provider_lane_resolved]
   event this module already emits for the ordinary "resolved" case) rather
   than introducing a new [event_kind] for one narrow signal. *)
let emit_context_overflow_shrink_manifest
      (ctx : try_provider_ctx)
      ~shrink_attempt
      ~previous_window_tokens
      ~window_tokens
  =
  emit_runtime_manifest ctx
    ~status:"context_overflow_shrink_retry"
    ~decision:
      (`Assoc
        [ "shrink_attempt", `Int shrink_attempt
        ; "previous_window_tokens", `Int previous_window_tokens
        ; "window_tokens", `Int window_tokens
        ; ( "declared_window_tokens"
          , `Int (Keeper_context_window.declared_tokens ctx.model_input_window) )
        ])
    Keeper_runtime_manifest.Provider_lane_resolved
;;

let accept_rejected_error ~runtime_id ~(response : Agent_core.Types.api_response) =
  let rejection =
    Keeper_tooling.Response.accept_rejection_of_response ~runtime_id response
  in
  let reason_kind =
    match rejection.kind with
    | Keeper_tooling.Response.No_usable_progress ->
      Some Keeper_internal_error.Accept_no_usable_progress
    | Keeper_tooling.Response.Predicate_rejected ->
      Some Keeper_internal_error.Accept_predicate_rejected
  in
  Keeper_internal_error.core_error_of_masc_internal_error
    (Keeper_internal_error.Accept_rejected
       {
         scope = runtime_id;
         model =
           Some
             (Boundary_redaction.to_string
                Boundary_redaction.runtime_model_label);
         reason_kind;
         response_shape =
           Option.map
             Keeper_internal_error.accept_response_shape_of_agent_core
             rejection.response_shape;
         (* RFC-0271 §4.5: preserve the provider's typed stop_reason so the
            classifier can tell a [MaxTokens] truncation from a clean [EndTurn]
            no-progress terminal. *)
         stop_reason = Some response.stop_reason;
         reason = rejection.reason;
       })

let apply_accept
      ~runtime_id
      ~accept
      (run_result : Runtime_agent.run_result)
  =
  match run_result.stop_reason with
  | Runtime_agent.InputRequired _
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    (* These are typed host-control terminals, not model deliverables. Running
       the normal response accept predicate over their question/blank carrier
       would turn them into [Accept_rejected] and incorrectly rotate providers,
       discarding typed control evidence. *)
    Ok run_result
  | Runtime_agent.Completed ->
    if accept run_result.response then Ok run_result
    else
      Error
        (accept_rejected_error
           ~runtime_id
           ~response:run_result.response)

(** Run a single provider attempt within the runtime.

    This is the extracted body of the [try_provider] closure that was
    defined inside [Keeper_turn_driver.run_named]. The [ctx] record
    makes all captured dependencies explicit.

    @param ctx Explicit closure context (captures from [run_named]).
    @param candidate The opaque runtime candidate to attempt.
    @return [(result, checkpoint_after, liveness_success_sample)] tuple. The
    sample is not recorded here; the caller records it only after the runtime
    accept predicate accepts the response. *)
let observe_checkpoint_stage observed (_ : Agent_core.Agent.checkpoint_stage) =
  Atomic.set observed true
;;

let same_run_retry_allowed observed = not (Atomic.get observed)

(* #28417: how often the stall watchdog samples the progress signal while a
   provider attempt runs. Small enough that the reported stall time stays
   close to the configured threshold, large enough that a fleet of keepers
   does not poll the registry continuously. Detection therefore lands in
   [threshold_sec, threshold_sec + progress_poll_interval_sec). *)
let progress_poll_interval_sec = 15.0

let attempt_stalled ~now ~threshold_sec ~attempt_started_at ~permit_wait ~sample =
  let judge ~attempt_started_at ~sample =
    match sample with
    | Some { last_progress_at; active_tool_count; awaiting_approval } ->
    (* A tool call that runs for minutes refreshes no progress signal while
       it runs, so tools in flight are work, not a stall. The 2026-08-12
       live attempt spent 120s inside one [Execute] and was healthy.

       A call held at the approval gate is the same shape and not the same
       fact: it is not the provider that has gone quiet, it is a person who
       has not answered yet. Cancelling the attempt there loses a turn the
       provider completed and files the loss against the provider. The wait
       has its own bound -- [Keeper_tool_approval_registry.await] races the
       answer against [timeout_sec] and settles either way -- so exempting it
       here does not leave anything unbounded. *)
    (not awaiting_approval)
    && active_tool_count = 0
    && now -. last_progress_at > threshold_sec
    | None ->
      (* Probe absent, or the keeper has no live turn observation to read.
         Falling back to elapsed time reproduces the pre-#28417 ceiling: losing
         the progress signal must not silently disable enforcement and leave a
         wedged attempt running unbounded. *)
      now -. attempt_started_at > threshold_sec
  in
  (* A wait for the binding's admission permit is queueing, not the provider
     gone quiet, and the only waits that write the cell are the bounded ones
     (Agent Core writes it for no other), so the admission bound ends it and
     nothing here needs to. Standing down for it leaves nothing unbounded,
     and the record then says [Queue] instead of racing the admission bound
     with a coarser clock. The wait's end is the instant the attempt's own
     budgets start from -- a stream granted late runs under its first-event
     budget from the grant -- so the watchdog counts from that instant too,
     as it counts from a lease's resumption, not from before the wait. *)
  match permit_wait with
  | Llm_provider.Provider_admission.Waiting_for_permit -> false
  | Llm_provider.Provider_admission.Before_any_wait -> judge ~attempt_started_at ~sample
  | Llm_provider.Provider_admission.Wait_settled_at settled_at ->
    judge
      ~attempt_started_at:(max settled_at attempt_started_at)
      ~sample:
        (Option.map
           (fun sample -> { sample with last_progress_at = max settled_at sample.last_progress_at })
           sample)
;;

type provider_lease_phase =
  | Provider_active_since of float
  | Provider_yielded

let observe_provider_lease ~now ~on_yield ~on_resume =
  let phase = Atomic.make (Provider_active_since (now ())) in
  let yield () =
    Atomic.set phase Provider_yielded;
    Option.iter (fun notify -> notify ()) on_yield
  in
  let resume () =
    Option.iter (fun notify -> notify ()) on_resume;
    Atomic.set phase (Provider_active_since (now ()))
  in
  phase, yield, resume
;;

let provider_lease_stalled ~lease_phase ~now ~threshold_sec ~attempt_started_at
    ~permit_wait ~sample =
  match lease_phase with
  | Provider_yielded -> false
  | Provider_active_since resumed_at ->
    let sample = Option.map (fun sample ->
      { sample with last_progress_at = max resumed_at sample.last_progress_at }) sample in
    attempt_stalled ~now ~threshold_sec
      ~attempt_started_at:(max resumed_at attempt_started_at) ~permit_wait ~sample
;;

(* #28417: blocks until the attempt has gone [threshold_sec] without a
   progress signal, then returns. [probe] is contracted not to raise (the
   injection site converts a failed registry read into [None]), so a
   transient read failure degrades this fiber to the elapsed fallback instead
   of cancelling the attempt it is watching. *)
let rec await_attempt_stall ~clock ~threshold_sec ~attempt_started_at ~probe
    ~lease_phase ~permit_wait =
  Eio.Time.sleep clock progress_poll_interval_sec;
  let sample =
    match probe with
    | Some read -> read ()
    | None -> None
  in
  (* [Time_compat.now], not [Eio.Time.now clock]: the value this is subtracted
     from ([turn_observation.last_progress_at]) is stamped by
     [Keeper_registry_setup.stamp_turn_progress] with [Time_compat.now], and a
     difference between two clocks is only meaningful when both readings come
     from the same one. [clock] is used for sleeping, not for dating. *)
  if provider_lease_stalled
       ~lease_phase:(Atomic.get lease_phase)
       ~now:(Time_compat.now ())
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:(Atomic.get permit_wait)
       ~sample
  then ()
  else await_attempt_stall ~clock ~threshold_sec ~attempt_started_at ~probe
    ~lease_phase ~permit_wait
;;

(* First-token-wait preemption (RFC-0441 pre-first-token gap). A person queued
   behind an autonomous turn whose provider has produced nothing has no tool
   boundary to be yielded at, so the attempt is abandoned and the slot goes to
   the person. It must fire only pre-first-token: once any streaming event
   arrives, the tool-boundary yield ([cooperative_yield_probe]) owns the
   handover. This is not a forced cancel of a productive turn -- the attempt
   produced nothing and re-runs fresh. *)
let preempt_pre_first_token ~first_event_seen ~person_queued =
  (not first_event_seen) && person_queued
;;

(* Matches the stall watchdog's cadence family: a person waits O(1s), not the
   ~600s first-event failsafe floor. *)
let person_queued_poll_interval_sec = 1.0

(* Blocks until a person is queued while the attempt is still pre-first-token,
   then returns to win the race. Once the first event lands ([first_event_seen])
   it never returns, ceding the verdict to the attempt and stall fibers.
   [person_queued] is contracted not to raise (the injection site maps a failed
   read to [false]), so a transient read never cancels the attempt it watches.

   [person_queued ()] reads the owner registry, which may schedule (an Eio mutex
   is a scheduling point), so the attempt fiber can flip [first_event_seen] while
   it runs. [first_event_seen] is therefore re-read AFTER the probe returns --
   [let queued] fixes that order -- and the read and the verdict have no
   scheduling point between them, so a turn that produced its first event during
   the probe is not preempted. Winning after a first event would only re-run a
   just-started attempt (a yield, not lost work), but the re-read keeps the
   "a responding turn is never preempted" property exact. *)
let rec await_person_queued_preemption ~clock ~first_event_seen ~person_queued =
  Eio.Time.sleep clock person_queued_poll_interval_sec;
  if Atomic.get first_event_seen
  then await_person_queued_preemption ~clock ~first_event_seen ~person_queued
  else
    let queued = person_queued () in
    if preempt_pre_first_token
         ~first_event_seen:(Atomic.get first_event_seen)
         ~person_queued:queued
    then ()
    else await_person_queued_preemption ~clock ~first_event_seen ~person_queued
;;

let rejected_body_bytes = function
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_too_large { actual_bytes; _ }; _ }) ->
    Some actual_bytes
  | Agent_core.Error.Api
      ( InvalidRequest
          { reason =
              ( Json_parse_error
              | Attempt_rejected
              | Request_body_refused_by_provider _
              | Refusal_body_not_received
              | Unknown_invalid_request )
          ; _
          }
      | ContextOverflow _
      | InputCapacity _
      | RateLimited _
      | Overloaded _
      | ServerError _
      | AuthError _
      | AuthorizationError _
      | PaymentRequired _
      | NotFound _
      | NetworkError _
      | Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Config _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _
  | Agent_core.Error.Internal_carried _ ->
    None
;;

let observe_request_wire_error
      ~runtime_id
      ~max_request_body_bytes
      ~on_request_wire_observation
      (error : Agent_core.Error.t)
  =
  match rejected_body_bytes error, on_request_wire_observation with
  | Some actual_bytes, Some observe ->
    (* AGENT_CORE measures this body before rejecting it at serialized-body admission,
       so its normal post-admission observer is intentionally not invoked. The
       typed refusal carries the same exact byte count; forwarding it here
       keeps the failed turn observable without parsing an error string or
       guessing which runtime attempted the request. *)
    observe
      ~runtime_id
      ~max_request_body_bytes
      ~body_bytes:actual_bytes
      ~serialized:None
  | None, _ | Some _, None ->
    ()
;;

(* The canonical MASC message encoder, also used for checkpoint serialization.
   It is not the provider's encoder, and the window reserves nothing for the
   difference: the token density it cuts against is observed over the bytes
   this encoder measured for a request, so whatever the wire adds on top is
   already inside the ratio (RFC keeper-context-window-in-tokens).

   [Yojson.Safe.to_string] is [to_buffer] followed by [Buffer.contents], so
   measuring through a buffer counts the same bytes and stops allocating a
   copy of every message to read its length. Projection measures the whole
   durable history per attempt, and a keeper turn makes 62 to 83 attempts.

   One buffer per measurer. A measurer is driven by one fiber, and its pool
   jobs run under [Eio.Executor_pool.submit_exn], which blocks until the job
   finishes, so two domains are never inside the buffer at once. [clear] keeps
   the capacity the largest message already paid for; the buffer dies with the
   measurer. *)
let message_measurer () =
  let buffer = Buffer.create 65536 in
  fun (message : Agent_core.Types.message) ->
    Buffer.clear buffer;
    Yojson.Safe.to_buffer buffer (Keeper_context_core.message_to_json message);
    Buffer.length buffer
;;

(* The memo is keyed by message value ([Agent_core.Types.Message_value]). Each
   request passes its history through [Complete_common.transmitted_history],
   which allocates a new record for every message
   ([Reasoning_history_projection.project]), so the key has to survive a rebuilt
   record. A float zero and its negative inside a raw JSON payload share one
   entry while encoding one byte apart; a byte is far inside the density the
   window is read through. *)
module Message_measurement_cache = Hashtbl.Make (Agent_core.Types.Message_value)

let memoize_message_measurement measure =
  let cache = Message_measurement_cache.create 128 in
  fun message ->
    match Message_measurement_cache.find_opt cache message with
    | Some bytes -> bytes
    | None ->
      let bytes = measure message in
      Message_measurement_cache.add cache message bytes;
      bytes
;;

(* Model-input projection walks the durable message history and encodes every
   candidate it measures. Live Keeper checkpoints carry tens of thousands of
   messages, so doing that work on the main Eio domain starves unrelated HTTP
   fibers even though no provider call has started yet. The server installs a
   shared CPU-weighted [Domain_pool]; non-Eio/unit callers retain the typed
   inline fallback owned by [Domain_pool_ref]. *)
let offload_model_input_cpu f = Domain_pool_ref.submit_cpu_or_inline f

(* The request bytes that are not conversation history, measured with the
   same encoder as the history: tool schemas and the system prompt. Charged
   against the window before any atom is considered. *)
let declared_request_reserve_bytes ~system_prompt ~tools =
  let tool_schema_bytes =
    List.fold_left
      (fun acc tool ->
         acc
         + String.length
             (Yojson.Safe.to_string (Agent_core.Tool.schema_to_json tool)))
      0
      tools
  in
  let system_prompt_bytes =
    String.length (Yojson.Safe.to_string (`String system_prompt))
  in
  tool_schema_bytes + system_prompt_bytes
;;

(* RFC-0363: the unmodified history chooses the authoritative cut first.
   Demotion then rewrites the atoms older than the current turn — the
   [demote_before] boundary the caller computes from [ctx.initial_messages]
   (RFC-0351 §4) — and the window cuts again against the smaller messages.
   Because that boundary moves once per turn, appending a message mid-turn
   cannot rewrite the transmitted prefix. The [history_atom_count] result is
   the atom count of that first cut — the only one taken against the whole
   history; every later cut sees a list that has already been shortened — so
   the reported share keeps that denominator.

   The window is a target, so no cut refuses (RFC
   keeper-context-window-in-tokens): when the parts no cut can remove pass
   the target, the newest atom is transmitted with the overrun reported and
   the provider judges its own context. One thing the target cannot answer
   is whether the provider will accept the bytes at all; that is the
   request-body cap's verdict, and it is the one axis on which this stage
   still reshapes a request. #28845, kept on that axis: when the smallest
   view that carries the turn would pass the declared cap, the composition
   is retried once with the demotion boundary moved past the newest atom
   ([demote_before = atom_count]), lifting the RFC-0351 §4 current-turn
   exclusion for that attempt only, so the turn's own tool results leave as
   externalized markers instead of the request being refused at the wire.
   If the atom carries nothing demotable, the view is transmitted as it is
   and the wire says no — a typed refusal with the exact size, which the
   lane already rotates on. A single last-resort attempt, not a retry
   loop. *)
let plan_and_window_model_input
      ~measure_message_bytes
      ~target_bytes
      ~reserved_bytes
      ~wire_cap_bytes
      ~base_path
      ~demote_before
      messages
  =
  let cut candidate =
    Runtime_model_input_tail_window.project_target
      ~measure_message_bytes
      ~target_bytes
      ~reserved_bytes
      candidate
  in
  let plan ~demote_before =
    if String.equal base_path "" || demote_before = 0
    then { Keeper_model_input_demotion.messages; pending = [] }
    else
      Keeper_model_input_demotion.plan
        ~measure_message_bytes
        ~demote_before
        messages
  in
  let raw = cut messages in
  let history_atom_count =
    raw.Runtime_model_input_tail_window.projection.atom_count
  in
  let cut_planned (planned : Keeper_model_input_demotion.plan_result) =
    match planned.Keeper_model_input_demotion.pending with
    | [] -> planned, raw, history_atom_count
    | _ :: _ ->
      planned, cut planned.Keeper_model_input_demotion.messages, history_atom_count
  in
  (* An overrun view is the smallest one that carries the turn: pinned
     context, the newest atom, the preamble. Above the cap, no window of any
     size would have made it transmittable. *)
  let smallest_view_passes_wire_cap =
    match raw.Runtime_model_input_tail_window.fit, wire_cap_bytes with
    | Runtime_model_input_tail_window.Overrun _, Some cap ->
      reserved_bytes + raw.Runtime_model_input_tail_window.transmitted_bytes > cap
    | Runtime_model_input_tail_window.Overrun _, None
    | Runtime_model_input_tail_window.Within_target, (Some _ | None) -> false
  in
  if smallest_view_passes_wire_cap
  then (
    let last_resort = plan ~demote_before:history_atom_count in
    match last_resort.Keeper_model_input_demotion.pending with
    | [] -> cut_planned (plan ~demote_before)
    | _ :: _ -> cut_planned last_resort)
  else cut_planned (plan ~demote_before)
;;

let projected_initial_message_count ~provider_config initial_messages =
  match initial_messages with
  | [] -> 0
  | initial ->
    (match
       Agent_core.Llm_provider.Complete_common.transmitted_history
         ~config:provider_config
         initial
     with
     | Ok projected -> List.length projected
     | Error _ -> List.length initial)
;;

(* The bounded transmission view runs here rather than in the caller because
   its capacity depends on the runtime: the window is declared in tokens
   ([ctx.model_input_window]) and the byte capacity one request cuts to comes
   from that runtime's observed token density, which the previous response on
   this very attempt may have just refined. A caller that composed the window
   ahead of runtime selection would have to guess which runtime's density
   applies. The window stays ahead of [ctx.model_input_projection] so that
   projection's projected-prefix precondition keeps holding against the list
   it receives.

   [last_request_measured_bytes] receives, per request, the bytes this stage
   measured for what it composed -- reservation and transmitted history --
   so the response's usage can be paired with them as one density
   observation. *)
let bounded_model_input_projection
      (ctx : try_provider_ctx)
      ~last_request_measured_bytes
      ~(provider_config : Llm_provider.Provider_config.t)
  : Agent_core.Agent.model_input_projection
  =
  let reserved_bytes =
    offload_model_input_cpu (fun () ->
      declared_request_reserve_bytes ~system_prompt:ctx.system_prompt ~tools:ctx.tools)
  in
  let initial_message_index =
    projected_initial_message_count ~provider_config ctx.initial_messages
  in
  (* One memo per provider attempt, not per request.  A turn issues one
     projection per provider request — measured on the live wire capture:
     83 requests for turn 12263, 62 for 15638 — and every request re-measures
     the same history, which is tens of thousands of messages on a live
     Keeper.  Building the memo inside the per-request closure threw that work
     away between requests.

     Safe to share: [run_try_provider] builds one closure per provider
     attempt, so no two Keepers share a memo; AGENT_CORE drives the turn loop
     sequentially (no [Fiber.fork] around [prepare_turn_for_agent] in
     pipeline_stage_prepare.ml); and [Domain_pool.submit_cpu] is
     [Eio.Executor_pool.submit_exn], which blocks until the job finishes, so
     successive jobs are ordered even when they land on different domains.

     The memo is keyed by message value ([Agent_core.Types.Message_value]), so
     a record that projection rebuilt for this request still hits the entry an
     earlier request measured. *)
  let measure_message_bytes = memoize_message_measurement (message_measurer ()) in
  (* Scoped to the attempt for the same reason and with the same safety: the
     demotion boundary is pinned to the turn's seed, so every request of this
     attempt demotes the same aged tool results, and addressing one is a
     sha256 over its whole body. Built inside the per-request closure it would
     be thrown away between the attempt's 62 to 83 requests, which is what it
     was before. *)
  let demotion_addresses = Keeper_model_input_demotion.create_address_memo () in
  (* Scoped to the attempt, written by the one fiber that drives it. The
     closure below runs per provider request — 62 to 83 of them in one keeper
     turn on the traces this window's own comment cites — and a keeper whose
     history carries a malformed tag falls back on every one of them, forever.
     Narrating that per request is the shape this codebase already had to undo
     once: [Reasoning_history_projection.observe]'s comment records a WARN
     firing ~973x/day about routine normalisation before it was demoted. *)
  let fallback_reported = ref false in
  (* Once per attempt, not per request, for the same reason: the window and
     its capacity as resolved for the first request, a capacity the
     request-body cap cannot carry, and an overrun. Each is a fact an
     operator reads against the declaration; none changes what is sent. *)
  let window_reported = ref false in
  let contradiction_reported = ref false in
  let overrun_reported = ref false in
  fun messages ->
    (* Measure the history the wire will carry, not the history the checkpoint
       holds. [Keeper_context_core.message_to_json] is the durable encoder — it
       must keep reasoning verbatim — but a dialect that replays none of it
       deletes every such block before serialization. Budgeting against the
       durable shape charges the window for bytes the provider never receives,
       and the room they take comes out of transmitted conversation: 23.6% of
       it on a live 2026-08-14 trace from a reasoning-heavy lane.

       The projection is the same one the serializer runs, through the same
       per-codec function, and it is idempotent — the backend applying it again
       to this output finds nothing left to drop. *)
    let messages, measurement =
      match
        Agent_core.Llm_provider.Complete_common.transmitted_history
          ~config:provider_config
          messages
      with
      | Ok transmitted -> transmitted, Turn_record.Wire_shape
      | Error error ->
        (* A refusal here must not become the turn's refusal. The projection
           validates reasoning provenance across the whole list it is given,
           and it is given the whole checkpoint — so one malformed tag anywhere
           in a keeper's lifetime would otherwise abort every later turn, with
           no typed overflow for the shrink retry to catch. Before this budget
           existed the same check ran only over the windowed tail, inside the
           backend, and still does: falling back to the durable shape restores
           exactly that scope. The cost is the narrower window this refinement
           was added to widen, which is the previous behaviour, not a new
           failure. *)
        if not !fallback_reported
        then (
          fallback_reported := true;
          Log.Keeper.warn
            "%s: model input measured against durable shape; reasoning \
             projection declined: %s"
            ctx.keeper_name
            (Agent_core.Llm_provider.Reasoning_history_projection
             .error_to_string
               error));
        messages, Turn_record.Durable_shape
    in
    let capacity =
      Keeper_context_window.capacity
        ctx.model_input_window
        (Keeper_context_window.Density.lookup ~runtime_id:ctx.runtime_id)
    in
    if not !window_reported
    then (
      window_reported := true;
      Log.Keeper.info
        ~keeper_name:ctx.keeper_name
        "model input window runtime=%s window=%s capacity=%s reserved_bytes=%d"
        ctx.runtime_id
        (Yojson.Safe.to_string (Keeper_context_window.to_json ctx.model_input_window))
        (Yojson.Safe.to_string (Keeper_context_window.capacity_to_json capacity))
        reserved_bytes);
    (match capacity, ctx.max_request_body_bytes with
     | ( Keeper_context_window.Measured { capacity_bytes; window_tokens; _ }
       , Some cap )
       when capacity_bytes > cap ->
       if not !contradiction_reported
       then (
         contradiction_reported := true;
         Log.Keeper.warn
           ~keeper_name:ctx.keeper_name
           "model input window contradicts the request-body cap runtime=%s: \
            %d tokens read as %d bytes at the observed density, above \
            max-request-body-bytes=%d; a request that fills the window is \
            refused at the wire"
           ctx.runtime_id
           window_tokens
           capacity_bytes
           cap)
     | Keeper_context_window.Measured _, (Some _ | None)
     | Keeper_context_window.Unmeasured _, (Some _ | None) -> ());
    let windowed, history_atom_count =
      match capacity with
      | Keeper_context_window.Unmeasured _ ->
        (* No density for this runtime yet, so no byte capacity stands for
           the window. The smallest request that still carries the turn is
           sent; its response reports usage, and the next request on this
           runtime cuts to the window. Nothing to demote: every older atom
           is already out. *)
        let projection, transmitted_bytes =
          offload_model_input_cpu (fun () ->
            Runtime_model_input_tail_window.project_newest_atom
              ~measure_message_bytes
              messages)
        in
        ( { Runtime_model_input_tail_window.projection
          ; fit = Runtime_model_input_tail_window.Within_target
          ; transmitted_bytes
          }
        , projection.Runtime_model_input_tail_window.atom_count )
      | Keeper_context_window.Measured { capacity_bytes; _ } ->
        let planned, windowed, history_atom_count =
          offload_model_input_cpu (fun () ->
            (* RFC-0351 §4: a tool result is cycle-scoped. What the keeper is
               reasoning over right now is what this turn produced, and
               [ctx.initial_messages] is exactly the history the turn was
               seeded with — so everything past it is this turn's own work and
               stays verbatim, and everything before it was already reported
               through a receipt or a board post and becomes a readable
               address.

               This is a boundary rather than a count of recent results. It
               also keeps the property the previous boundary was chosen for:
               appending a message cannot rewrite the retained prefix, because
               it moves once per turn rather than once per message. *)
            let demote_before =
              Runtime_model_input_tail_window.first_atom_at_or_after
                messages
                ~message_index:initial_message_index
            in
            plan_and_window_model_input
              ~measure_message_bytes
              ~target_bytes:capacity_bytes
              ~reserved_bytes
              ~wire_cap_bytes:ctx.max_request_body_bytes
              (* #27268 A/B kill-switch: an empty base path makes
                 [plan_and_window_model_input] keep every atom verbatim, so
                 the RFC-0363 demotion effect can be measured on and off in
                 one deployment. Default on preserves current behavior. *)
              ~base_path:
                (if Feature_flag_registry.get_bool "MASC_KEEPER_MODEL_INPUT_DEMOTION_ENABLED"
                 then ctx.base_path
                 else "")
              ~demote_before
              messages)
        in
        let windowed =
          match planned.Keeper_model_input_demotion.pending with
          | [] -> windowed
          | pending ->
            (* Blob materialization writes files, so it stays on the owning
               Eio fiber rather than in the CPU domain pool. The store skips
               writing an address this process already wrote, so on a
               long-lived keeper the sha256 over every aged body was all this
               call did, and it held this domain for one uninterrupted run of
               0.7 to 1.6 seconds per request (2026-09-16 trace). The attempt's
               memo answers every request after the first; whatever is left
               goes to the pool. *)
            let outcome =
              Keeper_model_input_demotion.materialize
                ~store:(Tool_blob_store.create ~base_path:ctx.base_path)
                ~addresses:demotion_addresses
                ~pending
                windowed.Runtime_model_input_tail_window.projection.messages
            in
            if outcome.Keeper_model_input_demotion.reverted = 0
            then
              (* Materialization rewrites bodies inside the already-chosen
                 cut; it neither adds nor removes atoms, so the counts still
                 hold, and a marker is never larger than the placeholder it
                 was measured as, so the measured bytes stand. *)
              { windowed with
                Runtime_model_input_tail_window.projection =
                  { windowed.Runtime_model_input_tail_window.projection with
                    Runtime_model_input_tail_window.messages =
                      outcome.Keeper_model_input_demotion.messages
                  }
              }
            else
              (* A restored body is larger than the measured placeholder, so
                 the final cut must be selected again against the actual
                 payload. *)
              offload_model_input_cpu (fun () ->
                Runtime_model_input_tail_window.project_target
                  ~measure_message_bytes:
                    (memoize_message_measurement (message_measurer ()))
                  ~target_bytes:capacity_bytes
                  ~reserved_bytes
                  outcome.Keeper_model_input_demotion.messages)
        in
        windowed, history_atom_count
    in
    (match windowed.Runtime_model_input_tail_window.fit with
     | Runtime_model_input_tail_window.Within_target -> ()
     | Runtime_model_input_tail_window.Overrun _ as fit ->
       if not !overrun_reported
       then (
         overrun_reported := true;
         Log.Keeper.warn
           ~keeper_name:ctx.keeper_name
           "model input window overrun runtime=%s fit=%s transmitted_bytes=%d \
            reserved_bytes=%d: the parts no cut can remove pass the window; \
            the provider judges whether they fit its context"
           ctx.runtime_id
           (Runtime_model_input_tail_window.target_fit_to_string fit)
           windowed.Runtime_model_input_tail_window.transmitted_bytes
           reserved_bytes));
    Option.iter
      (fun observe ->
         observe
           ~measurement
           (Runtime_model_input_tail_window.observe
              ~history_atom_count
              windowed.Runtime_model_input_tail_window.projection))
      ctx.on_model_input_window_observation;
    last_request_measured_bytes
    := Some (reserved_bytes + windowed.Runtime_model_input_tail_window.transmitted_bytes);
    let windowed = windowed.Runtime_model_input_tail_window.projection.messages in
    match ctx.model_input_projection with
    | None -> Ok windowed
    | Some inner -> inner windowed
;;

let run_try_provider ?continuation_checkpoint (ctx : try_provider_ctx) candidate =
  (* Named so the trace attributes runs during the provider attempt (request
     assembly, streaming, tool loop) to [turn:provider]. *)
  Eio_guard.with_named_switch "turn:provider" @@ fun () ->
  let resolved_lane =
    match ctx.tools with
    | [] -> "none"
    | _ :: _ -> "inline"
  in
  emit_runtime_manifest ctx
    ~status:"resolved"
    ~decision:(`Assoc [ "resolved_lane", `String resolved_lane ])
    Keeper_runtime_manifest.Provider_lane_resolved;
  let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    observe_checkpoint_stage ctx.checkpoint_stage_observed snapshot.stage;
    match ctx.checkpoint_sink with
    | Some sink -> sink snapshot
    | None -> Ok ()
  in
  (* The attempt's bounded wait for the binding's admission permit, as Agent
     Core writes it: on while the wait is on, then the instant it settled.
     The stall watchdog reads it on each poll. *)
  let permit_wait = Atomic.make Llm_provider.Provider_admission.Before_any_wait in
  (* The bytes the window measured for the request most recently composed on
     this attempt, paired below with the usage the provider reports for it:
     one observation of this runtime's token density. AGENT_CORE drives one
     request at a time inside an attempt, so the request the projection just
     measured is the one [AfterTurn] answers. *)
  let last_request_measured_bytes = ref None in
  let config_result =
    let base_config =
      Runtime_candidate.default_config
        ~name:ctx.name
        ~system_prompt:ctx.system_prompt
        ~tools:ctx.tools
        candidate
    in
    (* The gate's pre_tool_use runs before whatever hooks the turn brought:
       composed as [outer], so a call it holds never reaches them, and a call
       it lets through is still theirs to decide on. *)
    let hooks_with_gate =
      match ctx.approval_gate with
      | None -> ctx.hooks
      | Some (gate : Keeper_tool_approval_gate.t) ->
        let gate_hooks =
          { Agent_core.Hooks.empty with pre_tool_use = Some gate.pre_tool_use }
        in
        Some
          (match ctx.hooks with
           | None -> gate_hooks
           | Some hooks ->
             Agent_core.Hooks.compose ~outer:gate_hooks ~inner:hooks)
    in
    (* Token density observation (RFC keeper-context-window-in-tokens): the
       provider's inclusive prompt total for the request the window just
       measured. Composed outermost and always [Continue], so it neither
       delays nor decides anything the turn's own hooks do. *)
    let density_hooks =
      { Agent_core.Hooks.empty with
        after_turn =
          Some
            (function
              | Agent_core.Hooks.AfterTurn { response; _ } ->
                (match
                   response.Agent_core.Types.usage, !last_request_measured_bytes
                 with
                 | Some usage, Some measured_bytes ->
                   Keeper_context_window.Density.observe
                     ~runtime_id:ctx.runtime_id
                     ~measured_bytes
                     ~input_tokens:usage.Agent_core.Types.input_tokens
                 | Some _, None | None, (Some _ | None) -> ());
                Agent_core.Hooks.Continue
              | Agent_core.Hooks.BeforeTurn _
              | Agent_core.Hooks.BeforeTurnParams _
              | Agent_core.Hooks.PreToolUse _
              | Agent_core.Hooks.PostToolUse _
              | Agent_core.Hooks.PostToolUseFailure _
              | Agent_core.Hooks.OnStop _
              | Agent_core.Hooks.OnError _
              | Agent_core.Hooks.OnToolError _ -> Agent_core.Hooks.Continue)
      }
    in
    let hooks_with_gate =
      Some
        (match hooks_with_gate with
         | None -> density_hooks
         | Some hooks -> Agent_core.Hooks.compose ~outer:density_hooks ~inner:hooks)
    in
    (* Runtime/model configuration is authoritative; the run-level value only
       fills an omitted provider temperature. *)
    let temperature =
      match base_config.temperature with
      | Some _ as configured -> configured
      | None -> ctx.temperature
    in
    Ok
      { base_config with
        (* AGENT_CORE boundary: the keeper's two stream floors are always set,
           so the option AGENT_CORE reads is built here and nowhere else. *)
        stream_idle_timeout_s = Some ctx.stream_idle_timeout_s
          ; first_event_timeout_s = Some ctx.first_event_timeout_s
          ; body_timeout_s = ctx.body_timeout_s
          ; (* The wait for the binding's admission permit is time in which
               this attempt makes no progress, so the no-progress threshold
               is its bound too. Ended here it is a typed [Queue] timeout
               with nothing sent and the same rotation; left to the attempt
               watchdog it was "made no progress" with the queue invisible. *)
            admission_timeout_s = Some ctx.provider_call_deadline_sec
          ; permit_wait = Some permit_wait
          ; temperature
          ; hooks = hooks_with_gate
          ; tool_approval =
              Option.map
                (fun (gate : Keeper_tool_approval_gate.t) -> gate.tool_approval)
                ctx.approval_gate
          ; description =
              Some (Printf.sprintf "runtime:%s/runtime" ctx.runtime_id)
          ; runtime_id = Some ctx.runtime_id
          ; transport = ctx.transport_resolved
          ; checkpoint_sidecar = ctx.checkpoint_sidecar
          ; session_id = ctx.session_id
          ; cache_system_prompt = ctx.cache_system_prompt
          ; checkpoint_sink = Some checkpoint_sink
          ; context_injector = ctx.context_injector
          ; context = ctx.context
          ; enable_thinking = ctx.enable_thinking
          ; preserve_thinking = ctx.preserve_thinking
          ; event_bus = ctx.event_bus
          ; initial_messages = ctx.initial_messages
            (* The serialized request body is measured against an optional
               caller [max_request_body_bytes] cap. AGENT_CORE's provider-specific
               serialization boundary reports every admitted request; a typed
               [Request_body_too_large] below carries the exact rejected size.
               the canonical checkpoint's bytes cannot stand in
               for it — they cover [{system_prompt, messages}] and exclude
               tool schemas and every provider-specific stream field. AGENT_CORE runs
               this observer after those are injected and after its own
               admission check, so the value is the exact byte count.
               Diagnostic only: AGENT_CORE reports a rejection or a raised callback as
               typed failure evidence and does not rewrite the provider
               result. *)
            (* Serialising the admitted body walks every message in the request,
               on every provider request of the turn; on a live keeper that held
               the main domain for 168-229 ms at a time (RFC
               main-domain-scheduler-latency section 8.8). The pool runs it; the
               closure reads immutable request values only. *)
          ; serialization_executor =
              Some { Agent_core.Agent.run = Domain_pool_ref.submit_cpu_or_inline }
          ; pre_dispatch_serialization_observer =
              Some
                (fun observation ->
                   Option.iter
                     (fun observe ->
                        observe
                          ~runtime_id:ctx.runtime_id
                          ~max_request_body_bytes:ctx.max_request_body_bytes
                          ~body_bytes:
                            observation
                              .Llm_provider.Request_wire_observer.body_bytes
                          ~serialized:(Some observation))
                     ctx.on_request_wire_observation;
                   Ok ())
          ; raw_trace = ctx.raw_trace
          ; trace_link = ctx.trace_link
          ; yield_on_tool = ctx.yield_on_tool
            (* Read per turn rather than captured at boot so the ceiling can be
               tuned through the runtime-params API without a restart. *)
          ; max_tool_rounds = Keeper_config.keeper_max_tool_rounds ()
          }
  in
  (* The caller's cell when it has one, because the turn's tools captured it
     and [Runtime_agent.run] fills it at agent creation -- before any of them
     can execute. Not reset between attempts: a tool only runs inside an
     attempt that already filled it, and the value this leaves behind is the
     same one [checkpoint_after_attempt] wrote before. *)
  let attempt_agent_ref : Agent_core.Agent.t option ref =
    match ctx.agent_ref with
    | Some cell -> cell
    | None -> ref None
  in
  let agent_before_attempt = !attempt_agent_ref in
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    (* Installed here rather than on the record above because the projection
       needs the provider config that record is still producing: it measures
       the history that config's serializer will carry, and asking a config
       that does not exist yet would mean measuring something else. *)
    let config =
      { config with
        Runtime_agent.recovery_view =
          Option.map Keeper_recovery_transmission.runtime_projection ctx.recovery_view;
        model_input_projection =
          (match ctx.recovery_view with
           | Some _ -> ctx.model_input_projection
           | None ->
             Some
               (bounded_model_input_projection
                  ctx
                  ~last_request_measured_bytes
                  ~provider_config:config.Runtime_agent.provider_cfg))
      }
    in
    (* Explicit stream stall detection is handled by AGENT_CORE's
       [stream_idle_timeout_s]. No separate liveness FSM for the common
       case — provider stall is primarily an AGENT_CORE-level concern.
       #27349/#28417: [ctx.provider_call_deadline_sec] is the MASC-side
       no-progress ceiling on this whole attempt, armed below on every
       attempt. No per-lane capacity gate — provider load is managed by
       operator adjusting keeper count. *)
    let run_started_at =
      Unix.gettimeofday ()
      (* NDT-OK: provider-attempt latency telemetry only; dispatch/control
         decisions do not branch on this timestamp. *)
    in
    (* Tools and recovery judgment run after the main provider releases its
       inference lease. Observe that boundary synchronously: direct chat can
       lack the unified turn's asynchronous tool-count mirror. Its absence
       must not turn a running image subcall into a main-provider timeout.
       Delegated calls retain their own configured transport boundaries. *)
    let lease_phase, on_yield, on_resume =
      observe_provider_lease ~now:Time_compat.now
        ~on_yield:ctx.on_yield ~on_resume:ctx.on_resume
    in
    (* First-token-wait preemption arming. [first_event_seen] flips on the first
       streaming event of any kind -- a conservative "the provider has produced
       something" signal so a turn that is actually responding is never
       preempted (a post-first-event stall is owned by the stall watchdog and
       the idle bound). Only wrap [on_event] when the probe is present so the
       non-autonomous lanes keep their exact callback and 2-way race. *)
    let first_event_seen = Atomic.make false in
    let effective_on_event =
      match ctx.person_queued_probe with
      | None -> ctx.on_event
      | Some _ ->
        Some
          (fun ev ->
            Atomic.set first_event_seen true;
            Option.iter (fun f -> f ev) ctx.on_event)
    in
    let run_attempt_switch () =
      Eio.Switch.run (fun attempt_sw ->
        let run_fn () =
          Eio_guard.check_if_ready ();
          match continuation_checkpoint, ctx.goal_blocks with
          | Some checkpoint, _ ->
              Runtime_agent.continue_from_checkpoint
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ~checkpoint
                ?on_event:effective_on_event
                ~on_yield
                ~on_resume
                ~agent_ref:attempt_agent_ref
                ?cooperative_yield_probe:ctx.cooperative_yield_probe
                ()
          | None, Some blocks ->
              Runtime_agent.run_blocks
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?agent_core_checkpoint:ctx.agent_core_checkpoint
                ?on_event:effective_on_event
                ~on_yield
                ~on_resume
                ~agent_ref:attempt_agent_ref
                ?cooperative_yield_probe:ctx.cooperative_yield_probe
                blocks
          | None, None ->
              Runtime_agent.run
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?agent_core_checkpoint:ctx.agent_core_checkpoint
                ?on_event:effective_on_event
                ~on_yield
                ~on_resume
                ~agent_ref:attempt_agent_ref
                ?cooperative_yield_probe:ctx.cooperative_yield_probe
                ctx.goal
        in
        run_fn ())
    in
    (* #28417: the attempt races a stall watchdog through [Eio.Fiber.first],
       which cancels whichever fiber loses. This replaces #27349's
       [Eio.Time.with_timeout_exn] wrap because that primitive can only count
       elapsed time, while the verdict now depends on the keeper's progress
       signal — something only a polling fiber can observe.

       Cancellation semantics are unchanged: the attempt's own
       [Eio.Switch.run] still unwinds when it loses the race, and
       [Eio.Cancel.Cancelled] raised by an OUTER cancellation (switch
       shutdown, etc.) still propagates unmodified because neither branch
       catches it. AGENT_CORE's internal
       [stream_idle_timeout_s]/[body_timeout_s] firing remains a typed RETURN
       VALUE inside [Runtime_agent.run]'s result rather than an exception, so
       it still cannot be misclassified as this deadline firing. *)
    let threshold_sec = ctx.provider_call_deadline_sec in
    let result =
      match Eio_context.get_clock_opt () with
      | Some clock ->
        (* Same clock as [last_progress_at] (see [await_attempt_stall]): the
           elapsed fallback and the progress comparison must not read two
           different clocks. *)
        let attempt_started_at = Time_compat.now () in
        let attempt_fiber () = `Attempt_finished (run_attempt_switch ()) in
        let stall_fiber () =
          await_attempt_stall
            ~clock
            ~threshold_sec
            ~attempt_started_at
            ~lease_phase
            ~probe:ctx.provider_progress_probe
            ~permit_wait;
          `Attempt_stalled
        in
        (match
           (let combine_attempt_outcomes a b =
              (* A finished attempt stands even when it resolved in the same
                 scheduler pass the watchdog polled it stalled, or a person
                 queued: a provider answer that arrived must not be discarded
                 as a stall or a preemption and retried (#36340). *)
              match a, b with
              | `Attempt_finished _, _ -> a
              | _, `Attempt_finished _ -> b
              | `Attempt_preempted, _ -> a
              | _, `Attempt_preempted -> b
              | `Attempt_stalled, `Attempt_stalled -> a
            in
            match ctx.person_queued_probe with
            | None ->
              Eio.Fiber.first ~combine:combine_attempt_outcomes
                attempt_fiber stall_fiber
            | Some person_queued ->
              (* Third racer, autonomous-only: abandon a pre-first-token
                 attempt when a person queues (RFC-0441 gap). [Eio.Fiber.any]
                 cancels the losing siblings, unwinding the attempt's inner
                 [attempt_sw] and its in-flight request exactly as the stall
                 racer does; an outer cancellation still propagates because no
                 branch catches it. The same tie rule as the [None] arm keeps a
                 finished attempt over a simultaneous stall or preemption. *)
              Eio.Fiber.any ~combine:combine_attempt_outcomes
                [ attempt_fiber
                ; stall_fiber
                ; (fun () ->
                    await_person_queued_preemption
                      ~clock ~first_event_seen ~person_queued;
                    `Attempt_preempted)
                ])
         with
         | `Attempt_finished attempt_result -> attempt_result
         | `Attempt_preempted ->
           (* Synthesized zero-turn durable-stimulus yield: nothing was
              produced, no checkpoint, source wake stays pending and re-runs
              fresh. Not an error, so no provider rotation and no failure
              telemetry. *)
           (* [ctx.session_id] is the turn's trace id, always present on the
              autonomous lane where preemption is armed; the [None] arm names a
              deterministic fallback for this zero-turn yield's cosmetic id
              rather than defaulting an unknown input. *)
           let session_id =
             match ctx.session_id with
             | Some id -> id
             | None -> ctx.runtime_id
           in
           Ok (Runtime_agent.yielded_pre_first_token ~session_id)
         | `Attempt_stalled ->
           Error
             (Agent_core.Error.Api
                (Llm_provider.Retry.Timeout
                   { message =
                       Printf.sprintf
                         "provider call made no progress for %.0fs \
                          (runtime_id=%s)"
                         threshold_sec
                         ctx.runtime_id
                       (* [Wall_clock] is kept deliberately: the existing
                          classifiers
                          ([Runtime_attempt_fsm.should_try_next],
                          [Keeper_provider_runtime_boundary.is_provider_timeout_error])
                          already route this phase to declared-lane candidate
                          rotation, and this is still a wall-clock-derived
                          verdict. Introducing a new phase would change retry
                          policy, which #28417 does not intend to touch. *)
                   ; phase = Some Llm_provider.Http_client.Wall_clock
                   })))
      | None ->
        (* A process with no clock in [Eio_context] cannot count the
           threshold down. It could not run the attempt either:
           [Runtime_agent.build] reads the same [Eio_context.get_clock_opt]
           and refuses a stream-idle budget it has no clock to arm, and the
           driver always declares one. This arm refuses that condition one
           layer earlier, in the name of the deadline it could not set; the
           two read one clock source, so neither can run what the other
           refuses. The server installs its clock at boot before any turn,
           so a turn that gets here is a wiring fault; typed, and nothing
           was sent. *)
        Error
          (Agent_core.Error.Config
             (Agent_core.Error.InvalidConfig
                { field = "provider_call_deadline_sec"
                ; detail =
                    Printf.sprintf
                      "provider call attempt refused: this process has no \
                       clock to bound the %.0fs no-progress threshold with; \
                       nothing was sent (runtime_id=%s)"
                      threshold_sec
                      ctx.runtime_id
                }))
    in
    let result =
      match result with
      | Ok run_result ->
        (match
           apply_accept
             ~runtime_id:ctx.error_runtime_id
             ~accept:ctx.accept
             run_result
         with
         | Ok _ as accepted -> accepted
         | Error _ as rejected ->
           (* A rejected thinking-only response is a reasoning block the
              stream repeat guard did not end; keep the window it read so the
              miss can be explained (writes nothing for other shapes). *)
           Keeper_wire_capture.capture_rejected_reasoning
             ~base_path:ctx.base_path
             ~masc_root:(Common.masc_dir_from_base_path ~base_path:ctx.base_path)
             ~keeper_name:ctx.keeper_name
             ?turn_id:
               (Option.bind ctx.runtime_manifest_context
                  (fun (context : Keeper_runtime_manifest.turn_context) ->
                     context.manifest_keeper_turn_id))
             ?trace_id:ctx.session_id
             ~runtime_id:ctx.runtime_id
             run_result.response;
           rejected)
      | Error _ as err -> err
    in
    (match result with
     | Error error ->
       observe_request_wire_error
         ~runtime_id:ctx.runtime_id
         ~max_request_body_bytes:ctx.max_request_body_bytes
         ~on_request_wire_observation:ctx.on_request_wire_observation
         error
     | Ok _ -> ());
    (match ctx.on_runtime_observation, result with
     | Some emit, Ok run_result ->
       Option.iter emit run_result.Runtime_agent.runtime_observation
     | Some emit, Error err ->
       let total_duration_ms =
         (Unix.gettimeofday ()
          (* NDT-OK: closes the provider-attempt latency telemetry sample above. *)
          -. run_started_at)
         *. 1000.0
       in
       Runtime_agent.runtime_observation_for_terminal_config
         ~total_duration_ms
         ~error:(Agent_core.Error.to_string err)
         config
       |> emit
     | None, _ -> ());
    let checkpoint_after =
      Keeper_turn_driver_helpers.checkpoint_after_attempt
        ?agent_before_attempt ?session_id:ctx.session_id ?working_context:ctx.checkpoint_sidecar
        ?agent_ref:ctx.agent_ref
        !attempt_agent_ref
    in
    result, checkpoint_after, None
;;

(* #27320: same-runtime retry stage for a typed provider context overflow,
   inserted before [Keeper_turn_driver.attempt_runtime_candidates]' declared-
   lane candidate walk and its cascade rotation. A ContextOverflow on a
   request cut to the declared token window means the runtime's declared
   max-context, or the density the window was read through, over-states
   what this model carries -- not that the request was malformed: a smaller
   window of the SAME conversation can still answer the same turn, so this
   retries the same candidate rather than rotating runtimes immediately. *)
(* Halving needs no token/byte conversion constant: the provider is the
   oracle for whether a window fits. Each retry is a content-free mechanical
   convergence step consulted only after a typed overflow, not a size
   estimate. *)
let context_overflow_shrink_divisor = 2

let default_context_overflow_shrink_capacity ~capacity =
  capacity / context_overflow_shrink_divisor
;;

(* The shrink-retry policy is expressed over an injected [attempt] callback
   rather than calling [run_try_provider] directly, so it stays testable
   without an Eio-backed provider: [run_try_provider_with_context_overflow_shrink]
   below wires the real attempt for production; tests can inject a canned
   Ok/Error sequence to verify the halving sequence, the walk to the floor,
   and the same-run-retry-authority gate on their own.

   Classifies with [Keeper_turn_driver_try_runtime.context_overflow_should_try_next]
   rather than [Keeper_error_classify.is_context_overflow]: the latter
   depends on [Keeper_turn_driver], which depends on this module (it calls
   [run_try_provider]), so reaching it here would close a module cycle. Both
   predicates match the identical single case
   ([Agent_core.Error.Api (ContextOverflow _)] -> [true]); see that function's
   doc comment for why the byte-axis and token-axis siblings are excluded.
   [same_run_retry_authorized] mirrors the exact same-run authority gate
   [Keeper_turn_driver]'s declared-lane walk applies before rotating
   candidates ([same_run_retry_allowed] / [checkpoint_stage_observed]): a
   shrink retry is a same-run retry too, so it must not fire once AGENT_CORE has
   mutated agent state at a durable checkpoint stage. *)
let context_overflow_shrink_sequence
      ?(shrink_capacity = fun ~capacity:_ ~default_capacity ->
        default_capacity)
      ?(final_shrink_capacity = fun ~capacity:_ -> None)
      ~starting_capacity
      ~same_run_retry_authorized
      ~shrink_admits_history
      ~record_success
      ~on_shrink_retry
      ~(attempt : capacity:int -> ('ok, Agent_core.Error.t) result)
      ()
  : ('ok, Agent_core.Error.t) result
  =
  let rec go ~capacity ~shrink_attempt =
    match attempt ~capacity with
    | Ok _ as ok ->
      record_success ~capacity;
      ok
    | Error error as failed ->
      if Keeper_turn_driver_try_runtime.context_overflow_should_try_next error
         && same_run_retry_authorized ()
      then (
        let default_capacity =
          default_context_overflow_shrink_capacity ~capacity
        in
        let ordinary_capacity =
          shrink_capacity ~capacity ~default_capacity
        in
        (* The walk carries no attempt count: it ends where no strictly
           smaller view exists. A lane that has measured its floor names it
           through [final_shrink_capacity]; once the ordinary target would
           reach or pass that floor, the floor itself is the next attempt,
           and its refusal is the floor verdict. Measured 2026-09-05 on
           keeper geek-scout: a 4.1 MB history against a 128k-token model was
           refused at 1.9 MB, 507 KB and 498 KB and then committed as
           [Bootstrap_floor_exceeded] with 79 messages still attached; the
           floor had never been asked, and the keeper sat on an operator
           recovery it could have walked out of in two more attempts. *)
        let shrunk_capacity =
          match final_shrink_capacity ~capacity with
          | Some floor_capacity
            when ordinary_capacity <= floor_capacity ->
            floor_capacity
          | Some _ | None -> ordinary_capacity
        in
        (* Halving is a bet that the same request fits once less history
           rides along. The bet is void when the part that cannot be cut --
           tool schemas, system prompt, and the unmeasured-field allowance --
           already fills the smaller capacity: every atom would be dropped and
           the window would still refuse, one size lower. #31684 measured that
           on a live keeper: a 469638-byte reserve against capacities of
           131072 then 65536, three refusals per turn, none of which could
           have succeeded. Returning the original failure here hands the turn
           to the declared-lane walk, where a candidate with a larger
           request-body cap is the thing that can actually carry it. *)
        if shrunk_capacity >= capacity
           || not (shrink_admits_history ~capacity:shrunk_capacity)
        then failed
        else (
          on_shrink_retry
            ~shrink_attempt:(shrink_attempt + 1)
            ~previous_capacity:capacity
            ~capacity:shrunk_capacity;
          go
            ~capacity:shrunk_capacity
            ~shrink_attempt:(shrink_attempt + 1)))
      else failed
  in
  go ~capacity:starting_capacity ~shrink_attempt:0
;;

(** Same as [run_try_provider], except a typed provider context overflow
    retries the SAME candidate with the window halved, in tokens, down to
    the floor the reserve leaves, before returning to the caller, which
    still owns declared-lane candidate rotation and cascade fallback for
    every other error and for an overflow that survives every shrink
    attempt.

    The starting window for this (keeper, runtime) pair comes from
    {!Keeper_context_overflow_shrink_state}: the window that last completed
    a turn here, clamped to the declared window, so a keeper that has
    already discovered a working window does not rediscover it every turn.
    A successful attempt updates that memory. The window an attempt runs at
    carries its source, so a remembered or halved window is visible next to
    the declared one. *)
let run_try_provider_with_context_overflow_shrink
      ?continuation_checkpoint
      (ctx : try_provider_ctx)
      candidate
  =
  match ctx.recovery_view with
  | Some _ ->
    (* The validated semantic view owns retained source obligations. Retrying
       the same view with a smaller window cannot recover it. Final
       serialized request admission still enforces the request-body cap. *)
    run_try_provider ?continuation_checkpoint ctx candidate
  | None ->
  let declared_window = ctx.model_input_window in
  let starting_capacity =
    Keeper_context_overflow_shrink_state.starting_capacity
      ~keeper_name:ctx.keeper_name
      ~runtime_id:ctx.runtime_id
      ~max_capacity:(Keeper_context_window.declared_tokens declared_window)
  in
  let reserved_bytes =
    offload_model_input_cpu (fun () ->
      declared_request_reserve_bytes ~system_prompt:ctx.system_prompt ~tools:ctx.tools)
  in
  let checkpoint_after = ref None in
  let success_sample = ref None in
  let result =
    context_overflow_shrink_sequence
      ~starting_capacity
      ~same_run_retry_authorized:(fun () ->
        same_run_retry_allowed ctx.checkpoint_stage_observed)
      ~shrink_admits_history:(fun ~capacity ->
        (* The same reserve the window itself charges, read as tokens through
           this runtime's observed density. Below it the window has nothing
           left for history and a smaller one cannot succeed. With no density
           observed there is no account that could rule a size out, so the
           provider's verdict stands. *)
        match Keeper_context_window.Density.lookup ~runtime_id:ctx.runtime_id with
        | None -> true
        | Some density ->
          Keeper_context_window.tokens_of_bytes density reserved_bytes < capacity)
      ~record_success:(fun ~capacity ->
        Keeper_context_overflow_shrink_state.record_success
          ~keeper_name:ctx.keeper_name
          ~runtime_id:ctx.runtime_id
          ~capacity)
      ~on_shrink_retry:(fun ~shrink_attempt ~previous_capacity ~capacity ->
        emit_context_overflow_shrink_manifest
          ctx
          ~shrink_attempt
          ~previous_window_tokens:previous_capacity
          ~window_tokens:capacity)
      ~attempt:(fun ~capacity ->
        let attempt_result, attempt_checkpoint_after, attempt_success_sample =
          run_try_provider
            ?continuation_checkpoint
            { ctx with
              model_input_window =
                Keeper_context_window.with_tokens declared_window ~window_tokens:capacity
            }
            candidate
        in
        checkpoint_after := attempt_checkpoint_after;
        success_sample := attempt_success_sample;
        attempt_result)
      ()
  in
  (* An overflow that survived every admissible shrink says the remembered
     starting window no longer carries a turn here. Dropping it lets the
     next turn start from the declared window and measure again, instead of
     re-entering at a size this turn just disproved. Any other failure --
     network, auth, a stall -- says nothing about capacity, so the memory
     stands. *)
  (match result with
   | Ok _ -> ()
   | Error error ->
     if Keeper_turn_driver_try_runtime.context_overflow_should_try_next error
     then
       Keeper_context_overflow_shrink_state.forget
         ~keeper_name:ctx.keeper_name
         ~runtime_id:ctx.runtime_id);
  result, !checkpoint_after, !success_sample
;;

let checkpoint_before_incomplete_response (checkpoint : Agent_core.Checkpoint.t) =
  match List.rev checkpoint.messages with
  | ({ Agent_core.Types.role = Agent_core.Types.Assistant; _ } :
      Agent_core.Types.message)
    :: earlier ->
    Some { checkpoint with messages = List.rev earlier }
  | ({ role =
         ( Agent_core.Types.User
         | Agent_core.Types.System
         | Agent_core.Types.Tool )
       ; _
       } : Agent_core.Types.message)
    :: _
  | [] ->
    None
;;

(* Every no-progress rejection the provider stopped at [MaxTokens] cuts the
   checkpoint before the incomplete response. Whether that cut is followed by a
   continuation attempt is a separate question -- see
   [run_try_provider_with_truncation_recovery]. The retry kind is read
   afterwards, by the lane, to decide whether a failed or unreachable
   continuation rotates (no deliverable content) or ends the lane (partial
   content). *)
let max_tokens_truncation_error error =
  match Keeper_internal_error.classify_masc_internal_error error with
  | Some
      (Keeper_internal_error.Accept_rejected
         { reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
         ; stop_reason = Some Agent_core.Types.MaxTokens
         ; _
         }) ->
    true
  | Some
      ( Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Incomplete_tool_transcript _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      | Keeper_internal_error.Receipt_persistence_failed _
      | Keeper_internal_error.Gate_replay_repair_required _ )
  | None ->
    false
;;

let thinking_was_enabled = function
  | Some false -> false
  | Some true | None -> true
;;

(* What a max-tokens rejection owes the checkpoint. Two things were decided by
   one condition here, and only one of them is about thinking.

   Turning thinking off is the remedy for a budget spent thinking, so it is
   worth a second attempt only when thinking was on. Dropping the rejected
   response is owed either way: accept judged it unusable, and a checkpoint
   that keeps it feeds it back as input on every later turn.

   Measured on a live keeper, 2026-09-03, with thinking off throughout: the model
   collapsed into one repeated word, accept rejected it at max_tokens, and
   message_assistant_text climbed 136 KB -> 308 KB over twelve turns, stepping
   30-40 KB on each collapse -- the size of the rejected text. Larger input
   makes the next collapse likelier, so the refused response was financing its
   own repeat.

   Decided without running anything, so the decision is checkable on its own. *)
type truncation_recovery =
  | Recovery_not_applicable
  | Retry_without_thinking of Agent_core.Checkpoint.t
  | Drop_rejected_response of Agent_core.Checkpoint.t

let truncation_recovery ~enable_thinking ~result ~checkpoint =
  match result, checkpoint with
  | Error error, Some checkpoint when max_tokens_truncation_error error -> (
    match checkpoint_before_incomplete_response checkpoint with
    | None -> Recovery_not_applicable
    | Some cut ->
      if thinking_was_enabled enable_thinking
      then Retry_without_thinking cut
      else Drop_rejected_response cut)
  | Error _, _ | Ok _, _ -> Recovery_not_applicable
;;

(* A cut checkpoint is worth nothing unless the next turn loads it. The agent
   core's sink already persisted the checkpoint that carries the rejected
   response, at [After_assistant_collected]; this write, at the same turn
   count, replaces it. The lane's callers do not persist what this function
   returns: the Error branch drops [checkpoint_after], so the durable state
   would otherwise still hold the refused text. Measured on one measured Keeper,
   2026-09-05: the same 31 KB collapse sat in the checkpoint four times, one
   copy per rejected turn (#33267). *)
let persist_dropped_response
      ~(checkpoint_sink : Agent_core.Agent.checkpoint_sink option)
      ~now
      (cut : Agent_core.Checkpoint.t)
  =
  match checkpoint_sink with
  | None -> Ok ()
  | Some sink ->
    sink
      { Agent_core.Agent.stage = Agent_core.Agent.After_rejected_response_dropped
      ; turn = cut.turn_count
      ; checkpoint = cut
      ; timestamp = now
      }
;;

(* Effort is a thinking modifier: the wires that admit it at all reject the
   pair enable_thinking=false + reasoning_effort
   (backend_anthropic.validate_thinking_controls fails the request), so the
   no-thinking retry below must strip it from the candidate — otherwise the
   retry dies in request validation instead of continuing the turn it was
   meant to rescue. *)
let candidate_without_reasoning_effort (candidate : Runtime_candidate.t) : Runtime_candidate.t =
  Runtime_candidate.of_provider_config
    { (Runtime_candidate.provider_cfg candidate) with
      Llm_provider.Provider_config.reasoning_effort = None
    }
;;

let run_try_provider_with_truncation_recovery
      ?continuation_checkpoint
      (ctx : try_provider_ctx)
      candidate
  =
  let first_result, checkpoint_after, success_sample =
    run_try_provider_with_context_overflow_shrink ?continuation_checkpoint ctx candidate
  in
  match
    truncation_recovery
      ~enable_thinking:ctx.enable_thinking
      ~result:first_result
      ~checkpoint:checkpoint_after
  with
  | Recovery_not_applicable -> first_result, checkpoint_after, success_sample
  | Retry_without_thinking continuation_checkpoint ->
    emit_runtime_manifest ctx
      ~status:"max_tokens_continuation"
      ~decision:
        (`Assoc
          [ "continuation", `String "post_tool_checkpoint"
          ; "thinking", `String "disabled"
          ])
      Keeper_runtime_manifest.Provider_lane_resolved;
    run_try_provider
      ~continuation_checkpoint
      { ctx with enable_thinking = Some false; preserve_thinking = Some false }
      (candidate_without_reasoning_effort candidate)
  | Drop_rejected_response cut ->
    let persisted =
      persist_dropped_response
        ~checkpoint_sink:ctx.checkpoint_sink
        ~now:(Unix.gettimeofday ())
        cut
    in
    (match persisted with
     | Ok () -> ()
     | Error reason ->
       Log.Keeper.warn
         ~keeper_name:ctx.keeper_name
         "rejected response could not be dropped from the checkpoint and returns as \
          input next turn: %s"
         reason);
    emit_runtime_manifest ctx
      ~status:"max_tokens_rejected_response_dropped"
      ~decision:
        (`Assoc
          ([ "continuation", `String "none"
           ; "thinking", `String "already_disabled"
           ; ( "checkpoint_write"
             , `String
                 (match persisted with
                  | Ok () -> "installed"
                  | Error _ -> "refused") )
           ]
           @
           match persisted with
           | Ok () -> []
           | Error reason -> [ "refusal", `String reason ]))
      Keeper_runtime_manifest.Provider_lane_resolved;
    first_result, Some cut, success_sample
;;

module For_testing = struct
  let observe_provider_lease = observe_provider_lease
  let apply_accept = apply_accept
  let checkpoint_before_incomplete_response = checkpoint_before_incomplete_response
  let max_tokens_truncation_error = max_tokens_truncation_error

  type nonrec truncation_recovery = truncation_recovery =
    | Recovery_not_applicable
    | Retry_without_thinking of Agent_core.Checkpoint.t
    | Drop_rejected_response of Agent_core.Checkpoint.t

  let truncation_recovery = truncation_recovery
  let persist_dropped_response = persist_dropped_response
  let candidate_without_reasoning_effort = candidate_without_reasoning_effort
  let observe_request_wire_error = observe_request_wire_error
  let message_measurer = message_measurer
  let memoize_message_measurement = memoize_message_measurement
  let message_measurement_hash = Agent_core.Types.Message_value.hash
  let plan_and_window_model_input = plan_and_window_model_input
  let offload_model_input_cpu = offload_model_input_cpu
end
