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
  ; max_request_body_bytes : int
  ; (* #27320: the model-input windowing budget consulted by
       [budgeted_model_input_projection]. Starts at [max_request_body_bytes]
       (the runtime's declared wire cap) but is independently shrinkable:
       [run_try_provider_with_context_overflow_shrink] halves it on a typed
       provider context overflow and retries the SAME candidate, while
       [max_request_body_bytes] itself keeps reporting the real declared cap
       to wire-error diagnostics ([observe_request_wire_error],
       [pre_dispatch_serialization_observer]) so those never conflate a
       voluntary MASC-side reduction with the provider's actual admission
       limit. *)
    model_input_capacity_bytes : int
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
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
    (* Bound on the silent wait for the FIRST streaming provider event
       (TTFT/prefill), distinct from [stream_idle_timeout_s] which arms only
       after that event (RFC-AC-037). *)
  ; body_timeout_s : float option
  ; (* #27349, axis changed by #28417: the ceiling for THIS provider call
       attempt. Distinct from [stream_idle_timeout_s] (streaming inter-line
       gap) and [body_timeout_s] (non-streaming body read only): both of
       those are AGENT_CORE-internal and observe the transport only, which is
       why they left the non-streaming and pre-first-token (Admission/Queue)
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

       [None] (the operator has not set
       [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC] or
       [turn.provider_call_deadline_sec]) means no MASC-side enforcement. *)
    provider_call_deadline_sec : float option
  ; (* #28417: reads the keeper's live turn progress signal. Injected as a
       callback instead of calling [Keeper_registry] from here so the stall
       decision stays a pure function of its inputs (unit-testable with no
       registry on disk) and this module keeps its current dependency set.

       [None] disables progress-awareness and the deadline degrades to the
       pre-#28417 elapsed ceiling. That is the conservative direction: it can
       fire early on a healthy turn, never late on a wedged one. *)
    provider_progress_probe : (unit -> provider_progress_sample option) option
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
       max_request_body_bytes:int ->
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
      ~previous_capacity_bytes
      ~capacity_bytes
  =
  emit_runtime_manifest ctx
    ~status:"context_overflow_shrink_retry"
    ~decision:
      (`Assoc
        [ "shrink_attempt", `Int shrink_attempt
        ; "model_input_capacity_bytes", `Int capacity_bytes
        ; "max_request_body_bytes", `Int ctx.max_request_body_bytes
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
  | Runtime_agent.Awaiting_external_effect _
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

let attempt_stalled ~now ~threshold_sec ~attempt_started_at ~sample =
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
;;

(* #28417: blocks until the attempt has gone [threshold_sec] without a
   progress signal, then returns. [probe] is contracted not to raise (the
   injection site converts a failed registry read into [None]), so a
   transient read failure degrades this fiber to the elapsed fallback instead
   of cancelling the attempt it is watching. *)
let rec await_attempt_stall ~clock ~threshold_sec ~attempt_started_at ~probe =
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
  if attempt_stalled
       ~now:(Time_compat.now ())
       ~threshold_sec
       ~attempt_started_at
       ~sample
  then ()
  else await_attempt_stall ~clock ~threshold_sec ~attempt_started_at ~probe
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

(* Share of the declared request capacity held back for the parts of the
   serialized body MASC does not encode: provider-specific request fields, the
   JSON envelope, and any provider-side message reshaping. MASC measures
   messages, tool schemas, and the system prompt with its own encoder, but AGENT_CORE
   owns the wire format, so the remainder is bounded rather than computed.
   A share rather than a constant because the unmeasured remainder scales with
   the request. Under-reserving does not corrupt state — the provider refusal
   stays typed and the next assembly re-measures — so this trades transmitted
   history for refusal margin, not for correctness. *)
let unmeasured_request_reserve_divisor = 10

(* The canonical MASC message encoder, also used for checkpoint serialization.
   It is not the provider's encoder; [unmeasured_request_reserve_divisor]
   carries that difference. *)
let measure_message_bytes (message : Agent_core.Types.message) =
  String.length
    (Yojson.Safe.to_string (Keeper_context_core.message_to_json message))
;;

module Message_identity = struct
  type t = Agent_core.Types.message

  let equal left right = left == right

  let mix accumulator value = ((accumulator * 65599) lxor value) land max_int

  (* A constant-work string hint keeps the hash independent of tool-result body
     size. Equality remains physical, so collisions only share a bucket. *)
  let string_hint value =
    let length = String.length value in
    if length = 0
    then 0
    else
      let sample index = Char.code (String.unsafe_get value index) in
      mix
        (mix (mix (mix length (sample 0)) (sample (length / 3)))
           (sample ((2 * length) / 3)))
        (sample (length - 1))
  ;;

  let optional_string_hint = function
    | None -> 0
    | Some value -> string_hint value
  ;;

  let role_hint = function
    | Agent_core.Types.System -> 1
    | Agent_core.Types.User -> 2
    | Agent_core.Types.Assistant -> 3
    | Agent_core.Types.Tool -> 4
  ;;

  let hash (message : t) =
    mix
      (mix (role_hint message.role) (optional_string_hint message.name))
      (optional_string_hint message.tool_call_id)
  ;;
end

module Message_measurement_cache = Hashtbl.Make (Message_identity)

let memoize_message_measurement measure =
  (* A polymorphic hash would scan large strings inside the message. This
     table hashes only constant-size identity hints, then confirms hits with
     physical equality. *)
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

let declared_request_reserve_bytes ~capacity_bytes ~system_prompt ~tools =
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
  tool_schema_bytes
  + system_prompt_bytes
  + (capacity_bytes / unmeasured_request_reserve_divisor)
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

   #28845: with one exception. When the raw cut refuses with
   [Newest_atom_exceeds_available], the newest atom is indivisible and larger
   than the whole history budget, so no cut exists and there is no boundary to
   anchor to. The composition is retried once with the demotion boundary moved
   past the newest atom ([demote_before = atom_count]), lifting the RFC-0351
   §4 current-turn exclusion for that attempt only: the turn's own tool
   results are replaced by their externalized markers instead of failing the
   turn. If the atom carries nothing demotable, or still does not fit once
   demoted, the typed refusal stands — this is a single last-resort attempt,
   not a retry loop. *)
let plan_and_window_model_input
      ~measure_message_bytes
      ~capacity_bytes
      ~reserved_bytes
      ~base_path
      ~demote_before
      messages
  =
  let raw_cut candidate =
    Runtime_model_input_tail_window.project_with_drop
      ~measure_message_bytes
      ~capacity_bytes
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
  let cut_planned (planned : Keeper_model_input_demotion.plan_result) history_atom_count =
    match raw_cut planned.Keeper_model_input_demotion.messages with
    | Error _ as error -> error
    | Ok windowed -> Ok (planned, windowed, history_atom_count)
  in
  match raw_cut messages with
  | Error
      (Runtime_model_input_tail_window.Newest_atom_exceeds_available _ as
       first_error) ->
    (* #28845: no cut exists, so there is no raw-cut boundary to anchor
       demotion to. Retry the composition once with the boundary moved past
       the newest atom — lifting the RFC-0351 §4 current-turn exclusion for
       this attempt only — so the turn's own results leave as externalized
       markers instead of failing the turn. Nothing demotable, or still
       oversized once demoted, keeps the typed refusal. *)
    let _, atom_count = Runtime_model_input_tail_window.annotate messages in
    let planned = plan ~demote_before:atom_count in
    (match planned.Keeper_model_input_demotion.pending with
     | [] -> Error first_error
     | _ ->
       (match cut_planned planned atom_count with
        | Ok _ as ok -> ok
        | Error
            (Runtime_model_input_tail_window.Newest_atom_exceeds_available _) ->
          (* The re-cut measured the placeholder-saturated atom, so its
             [newest_atom_bytes] reports marker sizes and masks the true
             magnitude. Re-raise the refusal measured against the real
             bytes. *)
          Error first_error
        | Error _ as error -> error))
  | Error error -> Error error
  | Ok raw_projection ->
    let planned = plan ~demote_before in
    let history_atom_count = raw_projection.atom_count in
    (match planned.Keeper_model_input_demotion.pending with
     | [] -> Ok (planned, raw_projection, history_atom_count)
     | _ -> cut_planned planned history_atom_count)
;;

(* The bounded transmission view runs here rather than in the caller because
   its budget is [ctx.model_input_capacity_bytes], which
   [Keeper_turn_driver.validate_provider_request_cap] resolves per runtime
   (as [max_request_body_bytes]) and #27320's shrink retry may then lower
   for this specific attempt. A caller that composed the window ahead of
   runtime selection would have to guess which target's cap applies. The
   window stays ahead of [ctx.model_input_projection] so that projection's
   projected-prefix precondition keeps holding against the list it
   receives. *)
let budgeted_model_input_projection
      (ctx : try_provider_ctx)
      ~(provider_config : Llm_provider.Provider_config.t)
  : Agent_core.Agent.model_input_projection
  =
  let reserved_bytes =
    offload_model_input_cpu (fun () ->
      declared_request_reserve_bytes
        ~capacity_bytes:ctx.model_input_capacity_bytes
        ~system_prompt:ctx.system_prompt
        ~tools:ctx.tools)
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

     The message records are physically shared across a turn's requests — only
     the list spine is rebuilt — which is what makes the memo hit at all: it
     confirms every lookup with physical equality. *)
  let measure_message_bytes = memoize_message_measurement measure_message_bytes in
  (* Scoped to the attempt, written by the one fiber that drives it. The
     closure below runs per provider request — 62 to 83 of them in one keeper
     turn on the traces this window's own comment cites — and a keeper whose
     history carries a malformed tag falls back on every one of them, forever.
     Narrating that per request is the shape this codebase already had to undo
     once: [Reasoning_history_projection.observe]'s comment records a WARN
     firing ~973x/day about routine normalisation before it was demoted. *)
  let fallback_reported = ref false in
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
    let planned_and_windowed =
      offload_model_input_cpu (fun () ->
        (* RFC-0351 §4: a tool result is cycle-scoped. What the keeper is
           reasoning over right now is what this turn produced, and
           [ctx.initial_messages] is exactly the history the turn was seeded
           with — so everything past it is this turn's own work and stays
           verbatim, and everything before it was already reported through a
           receipt or a board post and becomes a readable address.

           This is a boundary rather than a count of recent results. It also
           keeps the property the previous boundary was chosen for: appending
           a message cannot rewrite the retained prefix, because it moves
           once per turn rather than once per message.

           One exception, exercised only when no cut exists at all: when the
           raw cut refuses with [Newest_atom_exceeds_available],
           [plan_and_window_model_input] retries once with the boundary moved
           past the newest atom, demoting this turn's own results into their
           externalized markers rather than failing the turn (#28845). *)
        let demote_before =
          Runtime_model_input_tail_window.first_atom_at_or_after
            messages
            ~message_index:(List.length ctx.initial_messages)
        in
        match
          plan_and_window_model_input
            ~measure_message_bytes
            ~capacity_bytes:ctx.model_input_capacity_bytes
            ~reserved_bytes
            ~base_path:ctx.base_path
            ~demote_before
            messages
        with
        | Error error ->
          Error (Runtime_model_input_tail_window.budget_error_to_core_error error)
        | Ok (planned, windowed, history_atom_count) ->
          Ok (planned, windowed, history_atom_count))
    in
    let windowed =
      match planned_and_windowed with
      | Error error -> Error error
      | Ok (planned, windowed, history_atom_count) ->
        let keep projection = Ok (projection, history_atom_count) in
        (match planned.Keeper_model_input_demotion.pending with
         | [] -> keep windowed
         | pending ->
           (* Blob materialization performs filesystem I/O and therefore stays
              on the owning Eio fiber rather than in the CPU domain pool. *)
           let outcome =
             Keeper_model_input_demotion.materialize
               ~store:(Tool_blob_store.create ~base_path:ctx.base_path)
               ~pending
               windowed.Runtime_model_input_tail_window.messages
           in
           if outcome.Keeper_model_input_demotion.reverted = 0
           then
             (* Materialization rewrites bodies inside the already-chosen cut;
                it neither adds nor removes atoms, so the counts still hold. *)
             keep
               { windowed with
                 Runtime_model_input_tail_window.messages =
                   outcome.Keeper_model_input_demotion.messages
               }
           else
             (* A restored body is larger than the measured placeholder, so the
                final cut must be selected again against the actual payload. *)
             (match
                offload_model_input_cpu (fun () ->
                  Runtime_model_input_tail_window.project_with_drop
                    ~measure_message_bytes:
                      (memoize_message_measurement measure_message_bytes)
                    ~capacity_bytes:ctx.model_input_capacity_bytes
                    ~reserved_bytes
                    outcome.Keeper_model_input_demotion.messages)
              with
              | Ok recut -> keep recut
              | Error error ->
                Error
                  (Runtime_model_input_tail_window.budget_error_to_core_error error)))
    in
    match windowed with
    | Error error -> Error error
    | Ok (windowed, history_atom_count) ->
      Option.iter
        (fun observe ->
           observe
             ~measurement
             (Runtime_model_input_tail_window.observe
                ~history_atom_count
                windowed))
        ctx.on_model_input_window_observation;
      let windowed = windowed.Runtime_model_input_tail_window.messages in
      (match ctx.model_input_projection with
       | None -> Ok windowed
       | Some inner -> inner windowed)
;;

let run_try_provider
      (ctx : try_provider_ctx)
      ?enable_thinking_override
      candidate
  =
  (* [enable_thinking_override] lets the caller re-issue the SAME candidate with a
     different thinking policy without mutating [ctx]. RFC-0271 §4.1 uses it for the
     [Retry_no_thinking] recovery arm: a [Thinking_only_no_progress] rejection is
     retried once with thinking forced off before rerouting to the next candidate. *)
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
    (* Runtime/model configuration is authoritative; the run-level value only
       fills an omitted provider temperature. *)
    let temperature =
      match base_config.temperature with
      | Some _ as configured -> configured
      | None -> ctx.temperature
    in
    Ok
      { base_config with
        stream_idle_timeout_s = ctx.stream_idle_timeout_s
          ; first_event_timeout_s = ctx.first_event_timeout_s
          ; body_timeout_s = ctx.body_timeout_s
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
          ; enable_thinking =
              (match enable_thinking_override with
               | Some v -> Some v
               | None -> ctx.enable_thinking)
          ; preserve_thinking = ctx.preserve_thinking
          ; event_bus = ctx.event_bus
          ; initial_messages = ctx.initial_messages
            (* The serialized request body is the quantity the provider admits
               against [max_request_body_bytes]. AGENT_CORE's provider-specific
               serialization boundary reports every admitted request; a typed
               [Request_body_too_large] below carries the exact rejected size.
               [Keeper_context_core_accessors.serialize_context] cannot stand in
               for it — that covers [{system_prompt, messages}] and excludes
               tool schemas and every provider-specific stream field. AGENT_CORE runs
               this observer after those are injected and after its own
               admission check, so the value is the exact byte count.
               Diagnostic only: AGENT_CORE reports a rejection or a raised callback as
               typed failure evidence and does not rewrite the provider
               result. *)
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
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    (* Installed here rather than on the record above because the projection
       needs the provider config that record is still producing: it measures
       the history that config's serializer will carry, and asking a config
       that does not exist yet would mean measuring something else. *)
    let config =
      { config with
        Runtime_agent.model_input_projection =
          Some
            (budgeted_model_input_projection
               ctx
               ~provider_config:config.Runtime_agent.provider_cfg)
      }
    in
    (* Explicit stream stall detection is handled by AGENT_CORE's
       [stream_idle_timeout_s]; [None] deliberately leaves it disabled.
       No separate liveness FSM for the common case — provider stall is
       primarily an AGENT_CORE-level concern. #27349: when the operator has set
       [ctx.provider_call_deadline_sec], the wrap below adds a total
       wall-clock ceiling on this whole attempt as a MASC-side backstop —
       still opt-in, off by default, same as before this existed.
       No per-lane capacity gate — provider load is managed by operator
       adjusting keeper count. *)
    let run_started_at =
      Unix.gettimeofday ()
      (* NDT-OK: provider-attempt latency telemetry only; dispatch/control
         decisions do not branch on this timestamp. *)
    in
    let run_attempt_switch () =
      Eio.Switch.run (fun attempt_sw ->
        let run_fn () =
          Eio_guard.check_if_ready ();
          match ctx.goal_blocks with
          | Some blocks ->
              Runtime_agent.run_blocks
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?agent_core_checkpoint:ctx.agent_core_checkpoint
                ?on_event:ctx.on_event
                ?on_yield:ctx.on_yield
                ?on_resume:ctx.on_resume
                ~agent_ref:attempt_agent_ref
                ?cooperative_yield_probe:ctx.cooperative_yield_probe
                blocks
          | None ->
              Runtime_agent.run
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?agent_core_checkpoint:ctx.agent_core_checkpoint
                ?on_event:ctx.on_event
                ?on_yield:ctx.on_yield
                ?on_resume:ctx.on_resume
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
    let result =
      match ctx.provider_call_deadline_sec, Eio_context.get_clock_opt () with
      | Some threshold_sec, Some clock ->
        (* Same clock as [last_progress_at] (see [await_attempt_stall]): the
           elapsed fallback and the progress comparison must not read two
           different clocks. *)
        let attempt_started_at = Time_compat.now () in
        (match
           Eio.Fiber.first
             (fun () -> `Attempt_finished (run_attempt_switch ()))
             (fun () ->
               await_attempt_stall
                 ~clock
                 ~threshold_sec
                 ~attempt_started_at
                 ~probe:ctx.provider_progress_probe;
               `Attempt_stalled)
         with
         | `Attempt_finished attempt_result -> attempt_result
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
      | None, _ | _, None -> run_attempt_switch ()
    in
    let result =
      match result with
      | Ok run_result ->
        apply_accept
          ~runtime_id:ctx.error_runtime_id
          ~accept:ctx.accept
          run_result
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
        ?agent_ref:ctx.agent_ref
        !attempt_agent_ref
    in
    result, checkpoint_after, None
;;

(* #27320: same-runtime retry stage for a typed provider context overflow,
   inserted before [Keeper_turn_driver.attempt_runtime_candidates]' declared-
   lane candidate walk and its cascade rotation. A ContextOverflow on a
   request that already fit [max_request_body_bytes] (the declared wire cap)
   means the byte cap under-bounds this target's token window, not that the
   request was malformed: a smaller window of the SAME conversation can
   still answer the same turn, so this retries the same candidate rather
   than rotating runtimes immediately. *)
let context_overflow_shrink_max_attempts = 3

(* Halving needs no token/byte conversion constant: the provider is the
   oracle for whether a window fits. Each retry is a content-free mechanical
   convergence step consulted only after a typed overflow, not a size
   estimate. *)
let context_overflow_shrink_divisor = 2

let default_context_overflow_shrink_capacity ~capacity_bytes =
  capacity_bytes / context_overflow_shrink_divisor
;;

(* The shrink-retry policy is expressed over an injected [attempt] callback
   rather than calling [run_try_provider] directly, so it stays testable
   without an Eio-backed provider: [run_try_provider_with_context_overflow_shrink]
   below wires the real attempt for production; tests can inject a canned
   Ok/Error sequence to verify the halving sequence, the attempt cap, and the
   same-run-retry-authority gate on their own.

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
      ?(shrink_capacity = fun ~capacity_bytes:_ ~default_capacity_bytes ->
        default_capacity_bytes)
      ?(final_shrink_capacity = fun ~capacity_bytes:_ -> None)
      ~starting_capacity_bytes
      ~same_run_retry_authorized
      ~shrink_admits_history
      ~record_success
      ~on_shrink_retry
      ~(attempt : capacity_bytes:int -> ('ok, Agent_core.Error.t) result)
      ()
  : ('ok, Agent_core.Error.t) result
  =
  let rec go ~capacity_bytes ~shrink_attempt =
    match attempt ~capacity_bytes with
    | Ok _ as ok ->
      record_success ~capacity_bytes;
      ok
    | Error error as failed ->
      if Keeper_turn_driver_try_runtime.context_overflow_should_try_next error
         && same_run_retry_authorized ()
         && shrink_attempt < context_overflow_shrink_max_attempts
      then (
        let default_capacity_bytes =
          default_context_overflow_shrink_capacity ~capacity_bytes
        in
        let ordinary_capacity_bytes =
          shrink_capacity ~capacity_bytes ~default_capacity_bytes
        in
        let shrunk_capacity_bytes =
          if shrink_attempt + 1 = context_overflow_shrink_max_attempts
          then
            Option.value
              (final_shrink_capacity ~capacity_bytes)
              ~default:ordinary_capacity_bytes
          else ordinary_capacity_bytes
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
        if shrunk_capacity_bytes >= capacity_bytes
           || not (shrink_admits_history ~capacity_bytes:shrunk_capacity_bytes)
        then failed
        else (
          on_shrink_retry
            ~shrink_attempt:(shrink_attempt + 1)
            ~previous_capacity_bytes:capacity_bytes
            ~capacity_bytes:shrunk_capacity_bytes;
          go
            ~capacity_bytes:shrunk_capacity_bytes
            ~shrink_attempt:(shrink_attempt + 1)))
      else failed
  in
  go ~capacity_bytes:starting_capacity_bytes ~shrink_attempt:0
;;

(** Same as [run_try_provider], except a typed provider context overflow
    retries the SAME candidate with the model-input windowing capacity
    halved (bounded by [context_overflow_shrink_max_attempts]) before
    returning to the caller, which still owns declared-lane candidate
    rotation and cascade fallback for every other error and for an overflow
    that survives every shrink attempt.

    The starting capacity for this (keeper, runtime) pair comes from
    {!Keeper_context_overflow_shrink_state}: the capacity that last
    completed a turn here, clamped to [ctx.max_request_body_bytes], so a
    keeper that has already discovered a working window does not
    rediscover it every turn. A successful attempt updates that memory. *)
let run_try_provider_with_context_overflow_shrink
      (ctx : try_provider_ctx)
      ?enable_thinking_override
      candidate
  =
  let starting_capacity_bytes =
    Keeper_context_overflow_shrink_state.starting_capacity_bytes
      ~keeper_name:ctx.keeper_name
      ~runtime_id:ctx.runtime_id
      ~max_capacity_bytes:ctx.max_request_body_bytes
  in
  let checkpoint_after = ref None in
  let success_sample = ref None in
  let result =
    context_overflow_shrink_sequence
      ~starting_capacity_bytes
      ~same_run_retry_authorized:(fun () ->
        same_run_retry_allowed ctx.checkpoint_stage_observed)
      ~shrink_admits_history:(fun ~capacity_bytes ->
        (* The same reserve account the window itself charges, measured at the
           capacity being proposed. Below it the window has nothing left for
           history and refuses whatever the conversation looks like. *)
        offload_model_input_cpu (fun () ->
          declared_request_reserve_bytes
            ~capacity_bytes
            ~system_prompt:ctx.system_prompt
            ~tools:ctx.tools)
        < capacity_bytes)
      ~record_success:(fun ~capacity_bytes ->
        Keeper_context_overflow_shrink_state.record_success
          ~keeper_name:ctx.keeper_name
          ~runtime_id:ctx.runtime_id
          ~capacity_bytes)
      ~on_shrink_retry:(fun ~shrink_attempt ~previous_capacity_bytes ~capacity_bytes ->
        emit_context_overflow_shrink_manifest
          ctx
          ~shrink_attempt
          ~previous_capacity_bytes
          ~capacity_bytes)
      ~attempt:(fun ~capacity_bytes ->
        let attempt_result, attempt_checkpoint_after, attempt_success_sample =
          run_try_provider
            { ctx with model_input_capacity_bytes = capacity_bytes }
            ?enable_thinking_override
            candidate
        in
        checkpoint_after := attempt_checkpoint_after;
        success_sample := attempt_success_sample;
        attempt_result)
      ()
  in
  (* An overflow that survived every admissible shrink says the remembered
     starting capacity no longer carries a turn here. Dropping it lets the
     next turn start from the runtime's declared cap and measure again,
     instead of re-entering at a size this turn just disproved. Any other
     failure -- network, auth, a stall -- says nothing about capacity, so the
     memory stands. *)
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

module For_testing = struct
  let apply_accept = apply_accept
  let observe_request_wire_error = observe_request_wire_error
  let memoize_message_measurement = memoize_message_measurement
  let plan_and_window_model_input = plan_and_window_model_input
  let offload_model_input_cpu = offload_model_input_cpu
  let context_overflow_shrink_max_attempts = context_overflow_shrink_max_attempts
  let context_overflow_shrink_divisor = context_overflow_shrink_divisor
end
