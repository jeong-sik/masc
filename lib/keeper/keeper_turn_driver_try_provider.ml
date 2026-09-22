(** Keeper_turn_driver_try_provider — extracted [try_provider] closure.

    RFC-0051 PR-3a: closure-to-toplevel-fn conversion with explicit ctx record.
    The [try_provider] closure was defined inside [Keeper_turn_driver.run_named]
    and captured ~51 variables from the enclosing scope. This module makes
    that boundary explicit via a record, so the compiler verifies every
    dependency and the function body is independently testable.

    @since RFC-0051 PR-3a *)


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

(* What this dispatch's checkpoints have recorded so far, strongest last. *)
type checkpoint_progress =
  | No_checkpoint_stage
  | Checkpoint_stage_reached
  | Tool_results_saved

type continuity =
  | Without_snapshot
  | Summarized of
  { snapshot : Librarian_continuity_snapshot.t
  ; covered_messages : Agent_core.Types.message list
  }
  | Absorbed of
  { trace_id : string
  ; end_atom : int
  ; last_atom_digest : string
  }

let without_snapshot = Without_snapshot

type continuity_choice =
  | Chose_no_point
  | Chose_a_librarian_point

(* The one question a caller outside this module asks of a continuity: did
   the turn start at a Librarian point, or at none? Answering it here keeps
   [continuity] abstract -- its constructors carry a snapshot checked against
   this dispatch's checkpoint, and nothing outside should be able to make
   one. *)
let continuity_choice = function
  | Without_snapshot -> Chose_no_point
  | Summarized _ | Absorbed _ -> Chose_a_librarian_point
;;

(* The Librarian's durable position, when it is a place in this history: the
   position names this trace and the atom before it opens with the message
   the position recorded -- the same test the Librarian's own range selection
   applies to its position (Keeper_librarian_range, RFC librarian-lifecycle
   section 4.4 row 5). A position of another trace, past this history, or
   over a message the history no longer holds at that index is no place here,
   and the caller falls back as it would with no position at all. *)
let absorbed_history ~trace_id ~messages (progress : Keeper_librarian_progress.t) =
  let position = progress.Keeper_librarian_progress.position in
  let end_atom = position.Keeper_librarian_progress.end_atom in
  if not (String.equal position.Keeper_librarian_progress.trace_id trace_id) || end_atom < 1
  then None
  else (
    match Runtime_model_input_tail_window.atom_opening_digest messages (end_atom - 1) with
    | Some opening when String.equal opening position.Keeper_librarian_progress.last_atom_digest ->
      Some
        ( end_atom
        , Absorbed
            { trace_id
            ; end_atom
            ; last_atom_digest = position.Keeper_librarian_progress.last_atom_digest
            } )
    | Some _ | None -> None)
;;

let covered_messages ~end_atom messages =
  let labelled, _ = Runtime_model_input_tail_window.annotate messages in
  List.filter_map (fun (message, label) -> match label with
    | Runtime_model_input_tail_window.Atom atom when atom < end_atom -> Some message
    | Runtime_model_input_tail_window.Atom _ | Runtime_model_input_tail_window.Pinned -> None)
    labelled
;;

let completed_history_end ~trace_id ~lines ~messages =
  Librarian_continuity_snapshot.checkpoint_prefix_range ~trace_id ~lines ~messages
  |> Result.map (fun range -> range.Keeper_librarian_range.end_atom)
;;

(* RFC keeper-context-window-in-tokens §13.4: where a request with no
   absorbed point starts. The end of the last completed turn on this
   history, verified against it; 0 when the history has no completed turn.
   A boundary store this process cannot read, or a boundary the history in
   hand does not match, is [Turn_boundary_unknown]: the range then opens on
   the newest atom alone and the origin says so, rather than on the whole
   history under a boundary that was never read (§13.4 does not fold an
   unknown start into 0). Under the small input policy no completed-turn
   boundary demotes tool bodies either. *)
let turn_start ~config ~keeper_name ~trace_id ~messages =
  let unknown reason =
    Log.Keeper.warn ~keeper_name
      "turn start unknown, the range opens on the newest atom alone: %s" reason;
    Keeper_carried_front.Turn_boundary_unknown { reason }
  in
  match
    Keeper_turn_boundaries.read
      ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
  with
  | Error detail -> unknown ("boundary read failed: " ^ detail)
  | Ok lines ->
    (match completed_history_end ~trace_id ~lines ~messages with
     | Ok end_atom -> Keeper_carried_front.Turn_boundary { end_atom }
     | Error Librarian_continuity_snapshot.Uncovered_history ->
       Keeper_carried_front.Turn_boundary { end_atom = 0 }
     | Error error -> unknown (Librarian_continuity_snapshot.error_to_string error))
;;

let prepare_continuity ~trace_id ~lines ~messages snapshot =
  Result.map (fun _ ->
    Summarized { snapshot; covered_messages = covered_messages ~end_atom:snapshot.Librarian_continuity_snapshot.end_atom messages })
    (Librarian_continuity_snapshot.restore ~trace_id ~lines ~messages snapshot)
;;

let validate_continuity ~messages = function
  | Without_snapshot -> Ok ()
  | Absorbed { end_atom; last_atom_digest; _ } ->
    (match Runtime_model_input_tail_window.atom_opening_digest messages (end_atom - 1) with
     | Some opening when String.equal opening last_atom_digest -> Ok ()
     | Some _ | None ->
       Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig
         { field = "librarian.progress"; detail = "Absorbed conversation changed during dispatch" })))
  | Summarized continuity ->
  let current = covered_messages ~end_atom:continuity.snapshot.end_atom messages in
  if List.equal Agent_core.Types.Message_value.equal current continuity.covered_messages
  then Ok ()
  else Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig
    { field = "librarian.continuity"; detail = "Covered conversation changed during dispatch" }))
;;

(* The turn's choice with the baseline the dispatch-time check compares
   against taken from [messages], the list one attempt starts from.

   The choice itself is the turn's and is made once, on the keeper's
   checkpoint history ([continuity_for_request]). A candidate can be handed
   another rendering of that same history: a runtime that cannot see an
   image is given a reading of it in the image's place, for that candidate
   alone (RFC-0265 media degrade, [Keeper_vision_ingest]). The bytes under
   the covered atoms differ then, while no atom moved and nothing was
   rewritten. Compared against the checkpoint's bytes, every request of such
   a candidate was refused: pr-updater answered nothing on 66 dispatches on
   2026-09-21 and 30 more the next day, 15 of them after walking the whole
   lane, with two image occurrences inside a snapshot that covered almost
   its entire history (#37812).

   Taken once per attempt from that attempt's own list, the per-request
   check answers the question it was written for: did this list change while
   the attempt was in flight. Whether the choice fits the history at all was
   already answered, against the history itself, when it was made. *)
let continuity_for_attempt ~messages = function
  | Without_snapshot -> Without_snapshot
  | Summarized { snapshot; covered_messages = _ } ->
    Summarized
      { snapshot
      ; covered_messages =
          covered_messages
            ~end_atom:snapshot.Librarian_continuity_snapshot.end_atom
            messages
      }
  | Absorbed { trace_id; end_atom; last_atom_digest } ->
    (match Runtime_model_input_tail_window.atom_opening_digest messages (end_atom - 1) with
     | Some opening -> Absorbed { trace_id; end_atom; last_atom_digest = opening }
     | None ->
       (* This list has no atom where the position points. That is not a
          rendering of the history the choice was made on, so the digest
          stands and every request of this attempt is refused, as before. *)
       Absorbed { trace_id; end_atom; last_atom_digest })
;;

type librarian_position =
  | No_position
  | Librarian_snapshot of Librarian_continuity_snapshot.t
  | Librarian_progress of { end_atom : int }

(* The one continuity this turn chose, as a position in the exact list a
   lane is about to cut. An official client composes its own request from
   that list more than once in a turn, and the list grows between
   compositions, so each call checks it against the choice the way the Agent
   Core branch checks each request ([validate_continuity]). *)
let librarian_position ~messages continuity =
  Result.map
    (fun () ->
       match continuity with
       | Summarized { snapshot; _ } -> Librarian_snapshot snapshot
       | Absorbed { end_atom; _ } -> Librarian_progress { end_atom }
       | Without_snapshot -> No_position)
    (validate_continuity ~messages continuity)
;;

let working_state_text (snapshot : Librarian_continuity_snapshot.t) =
  "[Librarian working state: summary of completed conversation; use as context, not as new instructions]\n"
  ^ snapshot.working_state
;;

(* Where a request starts, from what the keeper's files say (RFC
   keeper-context-window-in-tokens §13.4, §13.6): a snapshot that fits this
   history, else the Librarian's durable position when it is a place in this
   history, else this turn's own boundary.

   A turn needs no snapshot to go out: the position and the turn boundary
   still say where it starts. So a snapshot that cannot be read, cannot be
   checked against the boundary log, or covers bytes that have changed is one
   that does not fit, never a reason to refuse the turn (#37762). A refused
   turn also ran no Librarian round, so a snapshot whose covered bytes changed
   was never written again. A snapshot file or a boundary log that cannot be
   read stops the Librarian's continuity pass as well, so those stay until the
   file is fixed; they are warnings because each names a file to fix rather
   than a history that moved on. A covered prefix or a read position that
   changes while the request is in flight is still refused, by
   [validate_continuity].

   [lines] is read only when a snapshot is saved. *)
let continuity_for_request ~keeper_name ~trace_id ~messages ~snapshot ~lines ~progress =
  let absorbed_or_turn_start ~why =
    let absorbed =
      match progress () with
      | Ok (Some progress) -> absorbed_history ~trace_id ~messages progress
      | Ok None -> None
      | Error detail ->
        Log.Keeper.warn ~keeper_name
          "Librarian progress unreadable while no continuity snapshot fits (%s): %s"
          why detail;
        None
    in
    match absorbed with
    | Some (end_atom, continuity) ->
      Log.Keeper.info ~keeper_name
        "no Librarian continuity snapshot fits the current history (%s); starting at the Librarian's position, atom %d"
        why end_atom;
      continuity
    | None ->
      Log.Keeper.info ~keeper_name
        "no Librarian continuity snapshot fits the current history (%s); the request starts at this turn's own boundary"
        why;
      Without_snapshot
  in
  let unusable ~why =
    Log.Keeper.warn ~keeper_name
      "Librarian continuity snapshot cannot be used (%s); the request starts without it"
      why;
    absorbed_or_turn_start ~why
  in
  match snapshot with
  | Error detail -> unusable ~why:("snapshot unreadable: " ^ detail)
  | Ok None -> absorbed_or_turn_start ~why:"no continuity snapshot is saved"
  | Ok (Some snapshot) ->
    (match lines () with
     | Error detail -> unusable ~why:("turn boundaries unreadable: " ^ detail)
     | Ok lines ->
       (match prepare_continuity ~trace_id ~lines ~messages snapshot with
        | Ok restored ->
          (match snapshot.Librarian_continuity_snapshot.catch_up_end_atom with
           | None -> restored
           | Some target ->
             (* A rewrite from atom 0 that fits but has not reached where a
                request starts without it, as of the Librarian's last round:
                used now, it would move the start back and send everything
                after its end again. Checked after the fit, so a snapshot
                that also stopped fitting is logged as not fitting. *)
             absorbed_or_turn_start
               ~why:(Printf.sprintf
                       "the snapshot is being rewritten from atom 0 and ends at atom %d, short of %d"
                       snapshot.Librarian_continuity_snapshot.end_atom target))
        | Error
            ((Librarian_continuity_snapshot.Trace_mismatch
             | Librarian_continuity_snapshot.History_changed
             | Librarian_continuity_snapshot.Uncovered_history) as mismatch) ->
          (* The history moved on from the snapshot. The Librarian's durable
             position may still fit: goo-yang-bong's did on 2026-09-22 while
             its snapshot did not, and the keeper sent its 12,720 atoms,
             16.4 MB, 44 cycles in a row until the position was used. *)
          absorbed_or_turn_start ~why:(Librarian_continuity_snapshot.error_to_string mismatch)
        | Error
            ((Librarian_continuity_snapshot.Prefix_changed
             | Librarian_continuity_snapshot.Invalid_snapshot _
             | Librarian_continuity_snapshot.Range_stopped _
             | Librarian_continuity_snapshot.Read_failed _
             | Librarian_continuity_snapshot.Write_failed _) as error) ->
          unusable ~why:(Librarian_continuity_snapshot.error_to_string error)))
;;

(** Explicit context record for the extracted [try_provider] function.

    Each field corresponds to a variable captured by the original closure.
    Fields are grouped by role: runtime identity, agent config, transport,
    session/checkpoint, Eio primitives, callbacks, and event bus. *)
type try_provider_ctx =
  { (* Runtime identity *)
    runtime_id : string
  ; error_runtime_id : string
  ; (* The marks the carried range is judged against once per candidate turn,
       before its first composition (RFC keeper-context-window-in-tokens
       §10.5), declared on the binding. [None] leaves eviction to a refusal
       alone. *)
    context_marks : Runtime_schema.context_marks option
  ; (* Where the carried range starts when the process holds no ledger for
       this (keeper, runtime) pair: the range the newest completed Agent Core
       turn record on the trace measured, whichever runtime ran it. Read once
       per attempt, on that path only. *)
    carried_front_seed : unit -> Keeper_carried_front.seed_read
  ; continuity : continuity option
  ; input_policy : Keeper_input_policy.t
  ; turn_boundary : Keeper_carried_front.turn_start
  ; carried_front_after_refusal : unit -> Keeper_carried_front.seed option
  ; (* Where a front moved after a refusal is kept for the rest of the
       turn. The position is a fact about the history, not about the
       candidate that was refused, so the lane's next candidate composes
       from it instead of starting at the whole history again. *)
    hold_carried_front : Keeper_carried_front.seed -> unit
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
  ; checkpoint_progress : checkpoint_progress Atomic.t
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
       body_bytes:int ->
       serialized:Llm_provider.Request_wire_observer.observation option ->
       unit)
        option
  ; on_model_input_window_observation :
      (measurement:Turn_record.model_input_measurement
       -> Runtime_model_input_tail_window.window_observation
       -> unit)
        option
  ; on_response_observed_model_input :
      (Turn_record.response_observed_model_input -> unit) option
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

(* Records a same-runtime retry after a refusal moved the carried front, on
   the existing per-attempt manifest channel (the same [Provider_lane_resolved]
   event this module already emits for the ordinary "resolved" case) rather
   than a new [event_kind] for one narrow signal. *)
let emit_carried_range_retry_manifest (ctx : try_provider_ctx) ~retry decision =
  emit_runtime_manifest ctx
    ~status:"context_overflow_eviction_retry"
    ~decision:(`Assoc (("retry", `Int retry) :: decision))
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
(* Progress only moves forward: a later stage never erases a saved tool
   result, and a stage reached after one does not lower it. *)
let progress_advances ~current ~next =
  match current, next with
  | No_checkpoint_stage, (Checkpoint_stage_reached | Tool_results_saved)
  | Checkpoint_stage_reached, Tool_results_saved ->
    true
  | No_checkpoint_stage, No_checkpoint_stage
  | Checkpoint_stage_reached, (No_checkpoint_stage | Checkpoint_stage_reached)
  | Tool_results_saved, (No_checkpoint_stage | Checkpoint_stage_reached | Tool_results_saved) ->
    false
;;

let rec advance_checkpoint_progress progress next =
  let current = Atomic.get progress in
  if progress_advances ~current ~next
     && not (Atomic.compare_and_set progress current next)
  then advance_checkpoint_progress progress next
;;

let observe_checkpoint_stage progress (_ : Agent_core.Agent.checkpoint_stage) =
  advance_checkpoint_progress progress Checkpoint_stage_reached
;;

(* RFC last-path-resumes-after-progress §3.2: a chat operation resumes from its
   latest saved checkpoint, so only a stage written after tools ran, and
   written to that checkpoint, is progress a resumed attempt does not repeat.
   [After_assistant_collected] is saved before accept judges the answer and
   keeps a refused one, so counting it would resume into the same refusal.

   Only the sink's owner may call this. A sink answers [Ok ()] for a write it
   skipped as well as for one it made: the keeper's checkpoint store answers
   [Stale_noop] when the canonical checkpoint is already ahead of the incoming
   turn, and the keeper's sink turns that into [Ok ()]
   ([Keeper_agent_run], [Keeper_checkpoint_store.Stale_noop]). Reading progress
   off that answer would claim a checkpoint the operation would not resume
   from, and the tools it holds would run a second time. *)
let observe_checkpoint_saved progress (stage : Agent_core.Agent.checkpoint_stage) =
  match stage with
  | Agent_core.Agent.After_tool_results_appended
  | Agent_core.Agent.After_context_injection ->
    advance_checkpoint_progress progress Tool_results_saved
  | Agent_core.Agent.After_assistant_collected
  | Agent_core.Agent.After_rejected_response_dropped ->
    ()
;;

(* The stage is marked before the save is delegated: a failed save still ends
   same-run retry, because the attempt may already hold effects. What the sink
   did with the checkpoint is not read here -- its answer does not say whether
   anything was written -- so the sink's owner marks that itself with
   [observe_checkpoint_saved]. A dispatch whose owner marks nothing holds no
   saved tool results, and its lane's last candidate ends the turn as it did
   before this observation existed. *)
let observing_checkpoint_sink progress sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
  observe_checkpoint_stage progress snapshot.stage;
  match sink with
  | None -> Ok ()
  | Some sink -> sink snapshot
;;

let same_run_retry_allowed progress =
  match Atomic.get progress with
  | No_checkpoint_stage -> true
  | Checkpoint_stage_reached | Tool_results_saved -> false
;;

let tool_results_saved progress =
  match Atomic.get progress with
  | Tool_results_saved -> true
  | No_checkpoint_stage | Checkpoint_stage_reached -> false
;;

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


(* The memo is keyed by message value ([Agent_core.Types.Message_value]). Each
   request passes its history through [Complete_common.transmitted_history],
   which allocates a new record for every message
   ([Reasoning_history_projection.project]), so the key has to survive a rebuilt
   record. A float zero and its negative inside a raw JSON payload share one
   entry while encoding one byte apart; the bytes are judged against a cap
   of hundreds of kilobytes, and never converted to tokens. *)
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

(* The carried range as one request composes it (RFC
   keeper-context-window-in-tokens §10.4, §13.4, §13.6). With a Librarian
   continuity that fits this history the front is its position: the
   snapshot's, with the working state ahead of the range, or the read
   position alone. Without one the front comes from the ledger or its
   cold-start seed, and without either the range starts at the end of the
   last completed turn on this history ([completed_end_atom]), so only this
   turn's own atoms go out. Nothing here declares a cap.

   RFC-0363 demotion runs first over the unmodified history: the atoms older
   than the current turn — the [demote_before] boundary the caller computes
   from [ctx.initial_messages] (RFC-0351 §4) — have their aged tool results
   rewritten to readable addresses, and the range is then read off the
   rewritten list. Demotion neither adds nor removes atoms, so the front is
   the same position on both lists, and [history_atom_count] is the count
   of the whole history, which the reported share keeps as denominator.

   No cut refuses and nothing here measures a size against anything: the
   marks and the provider judge the request once it is counted, and the
   request body is the provider's to accept or refuse. #28845's demotion of
   the current turn's own tool results moved from composition time to the
   refusal path: when a refusal leaves nothing to evict and nothing to
   halve, the newest atom alone was refused, and [last_resort] composes the
   next request with the RFC-0351 §4 boundary moved past it
   ([demote_before = atom_count]) so those results leave as externalized
   markers. Once per attempt; if the atom carries nothing demotable there
   is no retry. *)
type composed =
  { planned : Keeper_model_input_demotion.plan_result
  ; projection : Runtime_model_input_tail_window.projection
  ; transmitted_bytes : int
  ; history_atom_count : int
  ; origin : Keeper_carried_front.origin
  ; outlived_seed : (Keeper_carried_front.seed * Keeper_carried_front.dropped_front) option
  ; demote_before : int
        (* The boundary the demotion actually applied: 0 when demotion is off,
           the whole history under the last resort. *)
  }

(* A request as the ledger reads it, with the history it was composed from:
   the ledger checks its last positions against that history, and a halving
   names its new front by it. *)
type sent_request =
  { request : Keeper_model_input_ledger.request
  ; digest_at : int -> string option
  }

(* What one provider attempt carries between its requests and the retry
   policy around it: its working ledger, the range the last request composed,
   whether the last resort is armed for the next composition, and how to ask
   whether arming it would change anything. *)
type attempt_state =
  { last_request : sent_request option ref
  ; ledger : Keeper_model_input_ledger.t option ref
  ; last_resort_armed : bool ref
  ; last_resort_probe : (unit -> bool) option ref
  }

(* The ledger's session: the history the carried positions belong to. The
   turn's trace id on the keeper's own turns; an attempt without one has no
   durable history and shares nothing. *)
let ledger_session (ctx : try_provider_ctx) =
  match ctx.session_id with
  | Some session -> session
  | None -> "-"
;;

(* The candidate can narrow its requests without turning a refused range
   into the next turn's starting point. AfterTurn records responses in the
   table; its observation also replaces this candidate's working value. *)
let new_attempt_state (ctx : try_provider_ctx) =
  { last_request = ref None
  ; ledger =
      ref
        (Keeper_model_input_ledger.Table.lookup
           ~keeper_name:ctx.keeper_name
           ~runtime_id:ctx.runtime_id
           ~session_id:(ledger_session ctx))
  ; last_resort_armed = ref false
  ; last_resort_probe = ref None
  }
;;

let move_ledger_front ledger ~first_atom ~front_digest =
  match !ledger with
  | None -> false
  | Some current ->
    (match Keeper_model_input_ledger.move_front current ~first_atom ~front_digest with
     | None -> false
     | Some moved ->
       ledger := Some moved;
       true)
;;

(* An empty base path turns demotion off, so no atom is below the boundary. *)
let applied_demote_before ~base_path ~demote_before =
  if String.equal base_path "" then 0 else demote_before
;;

let demotion_plan ~measure_message_bytes ~base_path ~demote_before messages =
  match applied_demote_before ~base_path ~demote_before with
  | 0 -> { Keeper_model_input_demotion.messages; pending = [] }
  | demote_before ->
    Keeper_model_input_demotion.plan ~measure_message_bytes ~demote_before messages
;;

(* Whether the last resort has anything to do: the current turn's own atoms
   carry a tool result the store could hold. *)
let last_resort_demotes ~measure_message_bytes ~base_path messages =
  let _labelled, atom_count = Runtime_model_input_tail_window.annotate messages in
  match
    (demotion_plan ~measure_message_bytes ~base_path ~demote_before:atom_count messages)
      .Keeper_model_input_demotion.pending
  with
  | [] -> false
  | _ :: _ -> true
;;

let compose_carried_model_input
      ?(input_policy = Keeper_input_policy.Wide)
      ?continuity
      ~measure_message_bytes
      ~(front : Keeper_carried_front.seed option)
      ~(history_digest_at : int -> string option)
      ~last_resort
      ~base_path
      ~demote_before
      ~turn_boundary
      messages
  =
  let _labelled, history_atom_count = Runtime_model_input_tail_window.annotate messages in
  (* A front whose index this history does not open with the same message
     names no atom of it: the history is shorter than the front, or a purge
     rewrote the message that opens it. The request starts over as with no front
     rather than carrying the newest atom alone from a position that would
     never widen again. A history that only lost an unsaved attempt's tail
     keeps the position. *)
  let front, outlived_seed =
    match continuity, front with
    | Some _, _ -> None, None
    | None, Some seed ->
      (match Keeper_carried_front.for_history ~digest_at:history_digest_at seed with
       | Ok seed -> Some seed, None
       | Error dropped -> None, Some (seed, dropped))
    | None, None -> None, None
  in
  let demote_before =
    match input_policy, continuity with
    | Keeper_input_policy.Small, _ -> demote_before
    | Keeper_input_policy.Wide, Some _ -> 0
    | Wide, None -> if last_resort then history_atom_count else demote_before in
  let planned =
    demotion_plan ~measure_message_bytes ~base_path ~demote_before messages
  in
  let projection, transmitted_bytes, origin =
    match continuity, front with
    | Some (Summarized { snapshot; _ }), _ ->
      let working : Agent_core.Types.message =
        { role = Agent_core.Types.User
        ; content = [ Agent_core.Types.Text (working_state_text snapshot) ]
        ; name = None; tool_call_id = None
        ; metadata = Runtime_model_input_tail_window.working_state_metadata
        }
      in
      let projection, transmitted_bytes =
        Runtime_model_input_tail_window.project_from_atom
          ~allow_empty_history:true
          ~history_already_announced:true ~measure_message_bytes
          ~first_atom:snapshot.end_atom
          (working :: planned.Keeper_model_input_demotion.messages)
      in
      projection, transmitted_bytes,
        Keeper_carried_front.Librarian_snapshot
          { end_atom = snapshot.end_atom; boundary_line = snapshot.end_boundary_line }
    | Some (Absorbed { end_atom; _ }), _ ->
      (* No summary stands in for the absorbed atoms; the omission preamble
         says older turns are left out, and an exclusive end at the newest
         atom -- a Librarian that has read everything, which is the only
         state a purge leaves it in -- carries no history atom at all. *)
      let projection, transmitted_bytes =
        Runtime_model_input_tail_window.project_from_atom
          ~allow_empty_history:true ~measure_message_bytes
          ~first_atom:end_atom
          planned.Keeper_model_input_demotion.messages
      in
      projection, transmitted_bytes, Keeper_carried_front.Librarian_progress { end_atom }
    | None, Some (seed : Keeper_carried_front.seed) ->
      let first_atom =
        Keeper_carried_front.clamp ~atom_count:history_atom_count seed.first_atom
      in
      (* A response-observed persisted seed is evidence for the range it names.
         Composition consumes that evidence; it does not reinterpret the prior
         outcome as a size refusal. The next refusal is answered by the in-turn
         ladder, which owns any further move toward the newest atom. *)
      let projection, transmitted_bytes =
        Runtime_model_input_tail_window.project_from_atom
          ~measure_message_bytes
          ~first_atom
          planned.Keeper_model_input_demotion.messages
      in
      projection, transmitted_bytes, Keeper_carried_front.Carried seed.source
    | None, None | Some Without_snapshot, _ ->
      (* No absorbed point and no seed (RFC keeper-context-window-in-tokens
         §13.4): the range begins where the last completed turn on this
         history ended, clamped so the newest atom always goes. The atoms
         before it wait for the Librarian's next pass. A history with no
         completed turn starts at 0, which is everything it has. The origin
         names the boundary itself, not the atom the clamp opened on. A
         boundary that could not be read opens on the newest atom alone,
         and the origin says so. *)
      let first_atom, origin =
        match turn_boundary with
        | Keeper_carried_front.Turn_boundary { end_atom } ->
          ( Keeper_carried_front.clamp ~atom_count:history_atom_count end_atom
          , Keeper_carried_front.Turn_start { end_atom } )
        | Keeper_carried_front.Turn_boundary_unknown { reason } ->
          ( Keeper_carried_front.newest_atom ~atom_count:history_atom_count
          , Keeper_carried_front.Turn_start_unknown { reason } )
      in
      let projection, transmitted_bytes =
        Runtime_model_input_tail_window.project_from_atom
          ~measure_message_bytes
          ~first_atom
          planned.Keeper_model_input_demotion.messages
      in
      projection, transmitted_bytes, origin
  in
  { planned
  ; projection
  ; transmitted_bytes
  ; history_atom_count
  ; origin
  ; outlived_seed
  ; demote_before = applied_demote_before ~base_path ~demote_before
  }
;;

(* One request: the range composed in the durable vocabulary, its demotions
   materialized, then the wire's view of the carried range. [composed] and
   [carried] count atoms of the checkpoint history — the vocabulary of the
   ledger, the seed and the forecast — and [wire] is the dialect's reasoning
   projection over [carried] alone, or why it declined. The order is the
   point: a position measured on one runtime names the same atom on every
   runtime whatever reasoning each dialect replays or deletes, a dialect that
   deletes a whole reasoning-only assistant message shortens the wire list
   and not the history the front is a position in, and the projection walks
   the carried range rather than the whole checkpoint. Projecting first
   would make the atom count a property of the dialect, so a front read from
   another runtime's record could fall under
   [Keeper_carried_front.for_history] and start the whole history over. *)
type request_view =
  { composed : composed
  ; carried : Agent_core.Types.message list
  ; wire :
      ( Agent_core.Types.message list
        , Agent_core.Llm_provider.Reasoning_history_projection.error )
        result
  }

let request_view
      ?(input_policy = Keeper_input_policy.Wide)
      ?continuity
      ~provider_config
      ~measure_message_bytes
      ~front
      ~history_digest_at
      ~last_resort
      ~base_path
      ~demote_before
      ~turn_boundary
      ~materialize
      messages
  =
  let composed =
    offload_model_input_cpu (fun () ->
      compose_carried_model_input
        ~input_policy ?continuity
        ~measure_message_bytes
        ~front
        ~history_digest_at
        ~last_resort
        ~base_path
        ~demote_before
        ~turn_boundary
        messages)
  in
  let carried =
    match composed.planned.Keeper_model_input_demotion.pending with
    | [] -> composed.projection.Runtime_model_input_tail_window.messages
    | pending -> materialize ~pending composed.projection.Runtime_model_input_tail_window.messages
  in
  let wire =
    offload_model_input_cpu (fun () ->
      Agent_core.Llm_provider.Complete_common.transmitted_history
        ~config:provider_config
        carried)
  in
  { composed; carried; wire }
;;

(* Where the next request's range starts (RFC keeper-context-window-in-tokens
   §10.3, §10.4). The candidate's working ledger answers only while this
   request's history still opens its front and newest atom with the
   messages it recorded; one that does not is dropped here, where the
   mismatch is first seen, and is returned so the caller can say so. The
   observed table entry is checked independently before being removed. Kept
   instead, its front would be dropped by [Keeper_carried_front.for_history]
   on every request while its stale blocks and front still answered the
   refusal path, which then retried the whole history without end. The cold
   seed is read only when no ledger answers. *)
let carried_front ~ledger ~keeper_name ~runtime_id ~session_id ~digest_at ~after_refusal ~cold =
  let after_refusal =
    Option.bind after_refusal (fun seed ->
      match Keeper_carried_front.for_history ~digest_at seed with
      | Ok seed -> Some seed
      | Error reason ->
        Log.Keeper.warn ~keeper_name
          "model input refusal front dropped runtime=%s reason=%s front=%s"
          runtime_id
          (Keeper_carried_front.dropped_front_to_string reason)
          (Yojson.Safe.to_string (Keeper_carried_front.seed_to_json seed));
        None)
  in
  let without_ledger () =
    match after_refusal with Some _ as front -> front | None -> cold ()
  in
  let dropped =
    match !ledger with
    | Some current when not (Keeper_model_input_ledger.holds ~digest_at current) ->
      (* Validate the actual table entry before removing it: another response
         may have replaced the snapshot this candidate started from. *)
      ledger :=
        (match
           Keeper_model_input_ledger.Table.lookup_in_history
             ~keeper_name ~runtime_id ~session_id ~digest_at
         with
         | Keeper_model_input_ledger.Table.Holds observed -> Some observed
         | Keeper_model_input_ledger.Table.Dropped_stale _
         | Keeper_model_input_ledger.Table.Absent -> None);
      Some current
    | Some _ | None -> None
  in
  match !ledger with
  | Some current ->
    let front = Keeper_carried_front.of_ledger current in
    (match after_refusal, front with
     | Some refused, Some carried when refused.first_atom > carried.first_atom ->
       Some refused, dropped
     | Some refused, None -> Some refused, dropped
     | (Some _ | None), (Some _ | None) -> front, dropped)
  | None -> without_ledger (), dropped
;;

(* The carried range runs here rather than in the caller because its front
   belongs to the (keeper, runtime) pair: the ledger the previous response on
   this very attempt may have just moved. A caller that composed the range
   ahead of runtime selection would have to guess which runtime's ledger
   applies. The range stays ahead of [ctx.model_input_projection] so that
   projection's projected-prefix precondition keeps holding against the list
   it receives.

   [state] receives, per request, the range this stage composed, so the
   response's usage can be written against it in the ledger and a refusal
   can be answered with a move of that very front; it hands this stage the
   armed last resort and takes back the probe that says whether arming it
   would change anything. *)
let bounded_model_input_projection
      (ctx : try_provider_ctx)
      ~(state : attempt_state)
      ~(provider_config : Llm_provider.Provider_config.t)
  : Agent_core.Agent.model_input_projection
  =
  let reserved_bytes =
    offload_model_input_cpu (fun () ->
      declared_request_reserve_bytes ~system_prompt:ctx.system_prompt ~tools:ctx.tools)
  in
  (* The fixed prefix the ledger compares consecutive requests under: one
     digest per attempt, since the system prompt and tool list are fixed for
     the attempt's lifetime. *)
  let prefix_digest =
    offload_model_input_cpu (fun () ->
      Keeper_model_input_ledger.prefix_digest
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

     The memo is keyed by message value ([Agent_core.Types.Message_value]), so
     a record that projection rebuilt for this request still hits the entry an
     earlier request measured. *)
  let measure_message_bytes =
    memoize_message_measurement (Keeper_context_core.message_measurer ())
  in
  (* Scoped to the attempt for the same reason and with the same safety: the
     demotion boundary is pinned to the turn's seed, so every request of this
     attempt demotes the same aged tool results, and addressing one is a
     sha256 over its whole body. Built inside the per-request closure it would
     be thrown away between the attempt's 62 to 83 requests, which is what it
     was before. *)
  let demotion_addresses = Keeper_model_input_demotion.create_address_memo () in
  let store_failure_reported = ref false in
  let reader_available = Result.is_ok (Keeper_recovery_transmission.require_reader ctx.tools) in
  let references_enabled = match ctx.input_policy, ctx.recovery_view with
    | Keeper_input_policy.Small, None ->
      reader_available
      && (match ctx.turn_boundary with
          | Keeper_carried_front.Turn_boundary { end_atom } -> end_atom > 0
          | Keeper_carried_front.Turn_boundary_unknown _ -> false)
    | _ -> false in
  let demotion_base_path = if references_enabled then ctx.base_path else "" in
  Log.Keeper.info ~keeper_name:ctx.keeper_name
    "input policy runtime=%s selected=%s context_owner=agent_core turn_boundary=%s blob_reader_available=%b body_externalization_enabled=%b"
    ctx.runtime_id (Keeper_input_policy.to_string ctx.input_policy)
    (Keeper_carried_front.turn_start_to_string ctx.turn_boundary) reader_available references_enabled;

  (* Scoped to the attempt, written by the one fiber that drives it. The
     closure below runs per provider request — 62 to 83 of them in one keeper
     turn on the traces this window's own comment cites — and a keeper whose
     carried range holds a malformed tag declines on every one of them until
     the range moves past it. Narrating that per request is the shape this
     codebase already had to undo once: [Reasoning_history_projection.observe]'s
     comment records a WARN firing ~973x/day about routine normalisation
     before it was demoted. *)
  let decline_reported = ref false in
  (* Once per attempt, not per request, for the same reason: where the range
     started for the first request, and a range that passes the request-body
     cap. Each is a fact an operator reads against the declaration; neither
     changes what is sent. *)
  let front_reported = ref false in
  let outlived_reported = ref false in
  (* The cold-start seed is read once per attempt and only when no ledger
     answers; every response updates the working ledger even without usage. *)
  let cold_seed = lazy (ctx.carried_front_seed ()) in
  fun messages ->
    let ( let* ) = Result.bind in
    let* () = match ctx.continuity with
      | None -> Ok ()
      | Some continuity -> offload_model_input_cpu (fun () -> validate_continuity ~messages continuity)
    in
    (* [messages] is the durable history, the checkpoint's messages, in which
       the ledger, the seed and the forecast count atoms; the range is
       composed in that vocabulary and the wire's projection runs afterwards
       over the carried range alone ([request_view]). *)
    let history_digest_at =
      offload_model_input_cpu (fun () ->
        Runtime_model_input_tail_window.atom_opening_digest messages)
    in
    let front, dropped_ledger =
      match ctx.continuity with
      | Some _ -> None, None
      | None -> carried_front
        ~ledger:state.ledger
        ~keeper_name:ctx.keeper_name
        ~runtime_id:ctx.runtime_id
        ~session_id:(ledger_session ctx)
        ~digest_at:history_digest_at
        ~after_refusal:(ctx.carried_front_after_refusal ())
        ~cold:(fun () -> (Lazy.force cold_seed).Keeper_carried_front.seed)
    in
    Option.iter
      (fun stale ->
         match !(state.ledger) with
         | Some observed ->
           Log.Keeper.info
             ~keeper_name:ctx.keeper_name
             "model input working ledger replaced runtime=%s: the history this request \
              composes from does not hold the working ledger; the observed table entry \
              does working=%s observed=%s"
             ctx.runtime_id
             (Yojson.Safe.to_string (Keeper_model_input_ledger.to_json stale))
             (Yojson.Safe.to_string (Keeper_model_input_ledger.to_json observed))
         | None ->
           Log.Keeper.info
             ~keeper_name:ctx.keeper_name
             "model input working ledger dropped runtime=%s: the history this request \
              composes from does not open the ledger's front or newest atom with the \
              message it recorded ledger=%s"
             ctx.runtime_id
             (Yojson.Safe.to_string (Keeper_model_input_ledger.to_json stale)))
      dropped_ledger;
    (* The last resort is consumed by one composition: the request it shapes
       is the retry the refusal asked for, and the requests after a success
       compose with the ordinary boundary again. *)
    let last_resort = !(state.last_resort_armed) in
    state.last_resort_armed := false;
    (* Completed-turn evidence, not attempt seed length, protects unfinished
       resumed tool work. Capacity refusal does not move this boundary. *)
    let demote_before =
      match ctx.turn_boundary with
      | Keeper_carried_front.Turn_boundary { end_atom } -> end_atom
      | Keeper_carried_front.Turn_boundary_unknown _ -> 0
    in
    state.last_resort_probe :=
      (match ctx.input_policy, ctx.continuity with
       | Keeper_input_policy.Small, _ | _, Some _ -> None
       | Wide, None -> Some (fun () -> offload_model_input_cpu (fun () ->
           last_resort_demotes ~measure_message_bytes ~base_path:demotion_base_path messages)));
    let view =
      request_view
        ~input_policy:ctx.input_policy ?continuity:ctx.continuity
        ~provider_config
        ~measure_message_bytes
        ~front
        ~history_digest_at
        ~last_resort
        ~base_path:demotion_base_path
        ~demote_before
        ~turn_boundary:ctx.turn_boundary
        ~materialize:(fun ~pending messages ->
          (* Blob materialization writes files, so it stays on the owning Eio
             fiber rather than in the CPU domain pool. The store skips writing
             an address this process already wrote, so on a long-lived keeper
             the sha256 over every aged body was all this call did, and it
             held this domain for one uninterrupted run of 0.7 to 1.6 seconds
             per request (2026-09-16 trace). The attempt's memo answers every
             request after the first; whatever is left goes to the pool.

             A reverted body is larger than the marker it was measured as; the
             range is a position, not a size, so the same atoms go out and the
             provider counts them. *)
          let outcome =
            Keeper_model_input_demotion.materialize
              ~store:(Tool_blob_store.create ~base_path:ctx.base_path)
              ~addresses:demotion_addresses
              ~pending
              messages
          in
          if outcome.Keeper_model_input_demotion.reverted > 0 && not !store_failure_reported then (
            store_failure_reported := true;
            Log.Keeper.warn ~keeper_name:ctx.keeper_name
              "input policy kept original tool bodies after externalization failure: count=%d"
              outcome.reverted);
          outcome.Keeper_model_input_demotion.messages)
        messages
    in
    let composed = view.composed in
    let history_atom_count = composed.history_atom_count in
    let windowed =
      match view.wire with
      | Ok transmitted -> transmitted
      | Error error ->
        (* The backend runs this same projection over this same list and
           refuses the request with its typed error, which the turn's failure
           route reads; the carried range is handed over for that refusal,
           and nothing is observed for a body that does not go out. A
           malformed tag outside the carried range no longer reaches the
           projection at all. *)
        if not !decline_reported
        then (
          decline_reported := true;
          Log.Keeper.warn
            "%s: reasoning projection declined over the carried range; the \
             backend refuses the request: %s"
            ctx.keeper_name
            (Agent_core.Llm_provider.Reasoning_history_projection
             .error_to_string
               error));
        view.carried
    in
    if not !front_reported
    then (
      front_reported := true;
      let transmitted_bytes =
        offload_model_input_cpu (fun () ->
          List.fold_left
            (fun sum message -> sum + measure_message_bytes message)
            0
            windowed)
      in
      Log.Keeper.info
        ~keeper_name:ctx.keeper_name
        "model input carried range runtime=%s origin=%s first_atom=%d atoms=%d/%d \
         transmitted_bytes=%d reserved_bytes=%d marks=%s last_resort=%b"
        ctx.runtime_id
        (Keeper_carried_front.origin_to_string composed.origin)
        composed.projection.Runtime_model_input_tail_window.dropped_atoms
        (history_atom_count - composed.projection.Runtime_model_input_tail_window.dropped_atoms)
        history_atom_count
        transmitted_bytes
        reserved_bytes
        (match ctx.context_marks with
         | Some marks ->
           Printf.sprintf "%d/%d" marks.high_water_tokens marks.low_water_tokens
         | None -> "none")
        last_resort;
      (* The cold seed is read only when no ledger answered; when it was, the
         records it could not decode and a refused turn-boundary store are
         part of why the range started where it did. *)
      if Lazy.is_val cold_seed
      then
        Keeper_carried_front.warn_seed_read_failures
          ~keeper_name:ctx.keeper_name
          ~runtime_id:ctx.runtime_id
          (Lazy.force cold_seed));
    (match composed.outlived_seed with
     | Some (seed, dropped) when not !outlived_reported ->
       outlived_reported := true;
       Log.Keeper.warn
         ~keeper_name:ctx.keeper_name
         "model input carried range dropped its front runtime=%s seed=%s reason=%s \
          history_atoms=%d: the history does not open that atom with the same message, \
          and the request starts over"
         ctx.runtime_id
         (Yojson.Safe.to_string (Keeper_carried_front.seed_to_json seed))
         (Keeper_carried_front.dropped_front_to_string dropped)
         history_atom_count
     | Some _ | None -> ());
    (match view.wire with
     | Ok _ ->
       Option.iter
         (fun observe ->
            Option.iter
              (observe ~measurement:Turn_record.Wire_shape)
              (Runtime_model_input_tail_window.observe
                 ~digest_at:history_digest_at
                 ~history_atom_count
                 composed.projection))
         ctx.on_model_input_window_observation
     | Error _ -> ());
    (* What this request carried, for the ledger the after-turn hook writes
       once the provider reports its count, and for the front a refusal
       moves: the carried atom range and the bytes of the per-request tail
       (the pinned messages), so a difference between two requests can be
       attributed to the atoms appended between them, and whether it carried
       the turn context, whose count is not a sample of the history. Read
       back from the carried list, in the durable vocabulary: the atoms in it
       and [history_atom_count] are absolute on every path, and the preamble
       is tail, not an atom, as the range itself treats it. *)
    (let transmitted_atoms, tail_bytes, turn_context =
       offload_model_input_cpu (fun () ->
         let history, preamble =
           List.partition
             (fun message ->
                not (Runtime_model_input_tail_window.is_synthetic_preamble message))
             view.carried
         in
         let labelled, transmitted_atoms =
           Runtime_model_input_tail_window.annotate history
         in
         let pinned_bytes =
           List.fold_left
             (fun sum (message, label) ->
                match label with
                | Runtime_model_input_tail_window.Pinned ->
                  sum + measure_message_bytes message
                | Runtime_model_input_tail_window.Atom _ -> sum)
             0
             labelled
         in
         let preamble_bytes =
           List.fold_left
             (fun sum message -> sum + measure_message_bytes message)
             0
             preamble
         in
         ( transmitted_atoms
         , pinned_bytes + preamble_bytes
         , List.exists Runtime_model_input_tail_window.is_extra_context history ))
     in
     let first_atom = history_atom_count - transmitted_atoms in
     (* Both positions are read off the lookup over the history the range was
        composed from, whose atom count [history_atom_count] is.
        - (Some, Some): the range carried atoms [first_atom] to the newest.
        - (None, None): the history has no atom; nothing was carried.
        - (None, Some _): the saved working state covers every history atom,
          so the request carries only pinned context and no raw atom.
        - (Some _, None): cannot occur. A front index below the atom count
          puts the newest index at or above it, and both are read from the
          same lookup.
        Every pair but the first records no position: the next observation
        checks nothing against it and starts no block from it. *)
     let ends =
       match
         history_digest_at first_atom, history_digest_at (history_atom_count - 1)
       with
       | Some front_digest, Some end_digest ->
         Keeper_model_input_ledger.Carried_atoms { front_digest; end_digest }
       | None, (Some _ | None) | Some _, None -> Keeper_model_input_ledger.No_atom_carried
     in
     state.last_request
     := Some
          { request =
              { Keeper_model_input_ledger.prefix_digest
              ; first_atom
              ; atom_count = history_atom_count
              ; ends
              ; tail_bytes
              ; turn_context
              ; demote_before = view.composed.demote_before
              }
          ; digest_at = history_digest_at
          });
    match ctx.model_input_projection with
    | None -> Ok windowed
    | Some inner -> inner windowed
;;

let run_try_provider_attempt ?continuation_checkpoint ~(state : attempt_state) (ctx : try_provider_ctx) candidate =
  let last_request = state.last_request in
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
  let checkpoint_sink =
    observing_checkpoint_sink ctx.checkpoint_progress ctx.checkpoint_sink
  in
  (* The attempt's bounded wait for the binding's admission permit, as Agent
     Core writes it: on while the wait is on, then the instant it settled.
     The stall watchdog reads it on each poll. *)
  let permit_wait = Atomic.make Llm_provider.Provider_admission.Before_any_wait in
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
    (* Usage observation (RFC keeper-context-window-in-tokens): the
       provider's inclusive prompt total for the request the composition just
       built. The ledger records the request's carried range against the
       count, one line per provider call, so block sizes, front moves and
       tail changes are read from the provider's numbers. The marks are not
       judged here: a front moved after a response would change the prefix of
       the turn's next request ([evict_at_turn_boundary]). Composed outermost
       and always [Continue], so it neither delays nor decides anything the
       turn's own hooks do. *)
    let ledger_hooks =
      { Agent_core.Hooks.empty with
        after_turn =
          Some
            (function
              | Agent_core.Hooks.AfterTurn { response; _ } ->
                (match !last_request with
                 | Some { request; digest_at } ->
                   (match request.Keeper_model_input_ledger.ends with
                    | Keeper_model_input_ledger.Carried_atoms
                        { front_digest; _ } ->
                      Option.iter
                        (fun observe ->
                           observe
                             { Turn_record.runtime_profile = ctx.runtime_id
                             ; window =
                                 { transmitted_atoms =
                                     request.atom_count - request.first_atom
                                 ; total_atoms = request.atom_count
                                 ; measurement = Turn_record.Wire_shape
                                 ; front_atom_digest = front_digest
                                 }
                             })
                        ctx.on_response_observed_model_input
                    | Keeper_model_input_ledger.No_atom_carried -> ());
                   let usage =
                     Option.bind response.Agent_core.Types.usage
                       (fun (u : Agent_core.Types.api_usage) ->
                          Keeper_model_input_ledger.usage_of_counts
                            ~input_tokens:u.input_tokens
                            ~cache_read_input_tokens:u.cache_read_input_tokens)
                   in
                   let observation =
                     Keeper_model_input_ledger.Table.observe
                       ~keeper_name:ctx.keeper_name
                       ~runtime_id:ctx.runtime_id
                       ~session_id:(ledger_session ctx)
                       ~digest_at
                       ~request
                       ~usage
                   in
                   state.ledger := Some observation.Keeper_model_input_ledger.ledger;
                   let line =
                     Yojson.Safe.to_string
                       (Keeper_model_input_ledger.observation_to_json observation)
                   in
                   (* The routine step is one line per provider call, so it
                      goes out at debug like the rest of this projection's
                      per-request narration; the events that change what the
                      ledger can attribute are rare and go out at info. *)
                   (match observation.Keeper_model_input_ledger.event with
                    | Keeper_model_input_ledger.Appended _
                    | Keeper_model_input_ledger.Repeated ->
                      Log.Keeper.debug
                        ~keeper_name:ctx.keeper_name
                        "model input ledger runtime=%s %s"
                        ctx.runtime_id
                        line
                    | Keeper_model_input_ledger.Started
                    | Keeper_model_input_ledger.Front_moved _
                    | Keeper_model_input_ledger.Front_cut_through_block _
                    | Keeper_model_input_ledger.Front_widened
                    | Keeper_model_input_ledger.Prefix_changed
                    | Keeper_model_input_ledger.History_reset ->
                      Log.Keeper.info
                        ~keeper_name:ctx.keeper_name
                        "model input ledger runtime=%s %s"
                        ctx.runtime_id
                        line)
                 | None -> ());
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
         | None -> ledger_hooks
         | Some hooks -> Agent_core.Hooks.compose ~outer:ledger_hooks ~inner:hooks)
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
            (* AGENT_CORE's provider-specific serialization boundary reports
               every request's exact body size; the canonical checkpoint's
               bytes cannot stand in for it — they cover
               [{system_prompt, messages}] and exclude tool schemas and every
               provider-specific stream field. AGENT_CORE runs this observer
               after those are injected, so the value is the exact byte count
               that reaches the provider. Diagnostic only: AGENT_CORE reports a
               raised callback as typed failure evidence and does not rewrite
               the provider result. *)
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
                   let input = match ctx.continuity with
                     | Some (Summarized {snapshot; _}) ->
                       Keeper_continuity_observation.Summarized
                         { trace_id = snapshot.trace_id; end_atom = snapshot.end_atom;
                           boundary_line = snapshot.end_boundary_line }
                     | Some (Absorbed { trace_id; end_atom; _ }) ->
                       Keeper_continuity_observation.Absorbed { trace_id; end_atom }
                     | Some Without_snapshot -> Keeper_continuity_observation.Without_snapshot
                     | None -> Keeper_continuity_observation.Not_applied in
                   if Option.is_some ctx.session_id then
                     Keeper_continuity_observation.record
                     ~config:(Workspace.default_config ctx.base_path) ~keeper_name:ctx.keeper_name
                     { prepared_at = Time_compat.now (); runtime_id = ctx.runtime_id; input;
                       request_bytes = observation.Llm_provider.Request_wire_observer.body_bytes };
                   Option.iter
                     (fun observe ->
                        observe
                          ~runtime_id:ctx.runtime_id
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
                  ~state
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

(* #27320: same-runtime retry stage for a typed provider context overflow on
   the official-client lanes, whose seed history is cut against a declared
   prompt byte cap ([Keeper_claude_code_runtime], [Keeper_codex_runtime]).
   A ContextOverflow there means the cap over-states what the client
   carries, not that the request was malformed: a smaller view of the SAME
   conversation can still answer the same turn, so the lane retries the same
   candidate rather than rotating runtimes immediately. The Agent Core lane
   answers the same refusal by moving the carried front instead
   ([run_try_provider_with_carried_range_eviction]). *)
(* Halving needs no token/byte conversion constant: the provider is the
   oracle for whether a view fits. Each retry is a content-free mechanical
   convergence step consulted only after a typed overflow, not a size
   estimate. *)
let context_overflow_shrink_divisor = 2

let default_context_overflow_shrink_capacity ~capacity =
  capacity / context_overflow_shrink_divisor
;;

(* The shrink-retry policy is expressed over an injected [attempt] callback
   so it stays testable without an Eio-backed provider: the official-client
   lanes wire their real attempt for production; tests can inject a canned
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
   candidates ([same_run_retry_allowed] / [checkpoint_progress]): a
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

(* The refusals that say the request outgrew what carries it: the provider's
   context overflow, and the two size refusals on the byte axis, masc's own
   against the declared request-body cap and the provider's without a bound.
   Each is answered by moving the carried front, never by rotating first: a
   shorter range of the SAME conversation can still answer the same turn.
   Enumerated so a new variant forces a decision here instead of a silent
   [false]. *)
let refusal_evicts = function
  | Agent_core.Error.Api (ContextOverflow _)
  | Agent_core.Error.Api
      (InvalidRequest { reason = Request_body_refused_by_provider _; _ })
  (* A refusal whose reason agent core does not model is still a refusal OF
     THIS REQUEST: the provider read it and declined it. Resending the same
     bytes draws the same answer, so the only lever left is to carry less.
     The sequence retries only while the front moves strictly later and
     returns the refusal once a single atom is left, so this bounds at
     log2(atoms) attempts rather than looping.

     2026-09-18: five keepers sat in that loop. After the turn-record hard
     cut (#36955) every seed was unreadable, each turn composed the whole
     history, the provider refused the 15 MB body (a modelled body refusal,
     one halving), and then refused 9.5 MB with an error body whose only
     field is prose naming the prompt tokens and the model limit. That prose
     stays Unknown_invalid_request on purpose -- Retry.classify_error has
     tests pinning it, because reading the sentence would be a string
     classifier. The turn ended and the next turn started over. *)
  | Agent_core.Error.Api (InvalidRequest { reason = Unknown_invalid_request; _ }) ->
    true
  | Agent_core.Error.Api
      ( InvalidRequest
          { reason =
              (Json_parse_error | Attempt_rejected | Refusal_body_not_received)
          ; _
          }
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
  | Agent_core.Error.Internal_carried _ -> false
;;

type eviction_retry =
  | Evicted_blocks of Keeper_carried_range.step
  | Halved_range of
      { first_atom : int
      ; atom_count : int
      }
  | Demoted_newest_atom

let eviction_retry_to_json = function
  | Evicted_blocks step ->
    [ "kind", `String "evicted_blocks"; "step", Keeper_carried_range.step_to_json step ]
  | Halved_range { first_atom; atom_count } ->
    [ "kind", `String "halved_range"
    ; "first_atom", `Int first_atom
    ; "atom_count", `Int atom_count
    ]
  | Demoted_newest_atom -> [ "kind", `String "demoted_newest_atom" ]
;;

(* The eviction-retry policy over an injected [attempt], testable without a
   provider (RFC keeper-context-window-in-tokens §10.5). A refusal that
   [refusal_evicts] is answered from the pair's ledger with
   [Keeper_carried_range.after_overflow]: the oldest blocks leave and the
   same candidate is asked again. When the ledger has no block structure to
   walk — no usage counted yet on this pair, or a single block — the range
   halves toward the newest atom instead, and stops at a single atom. When
   that single atom is what was refused, [last_resort] may arm #28845's
   demotion of the turn's own tool results for one more request; it answers
   [false] once used or when there is nothing to demote, and the refusal
   stands. Every step is a position on the atom axis chosen against the
   provider's verdict; nothing measures the request against a limit of its
   own. Every retry follows a move: [evict] and [halve] answer whether the
   next composition carries a strictly later front, and [false] ends the
   sequence with the refusal in hand, so no retry resends the range that was
   refused. [same_run_retry_authorized]
   is the same gate [Keeper_turn_driver]'s declared-lane walk applies before
   rotating candidates: a retry here is a same-run retry too, so it must not
   fire once AGENT_CORE has mutated agent state at a durable checkpoint
   stage. *)
let carried_range_eviction_sequence
      ~same_run_retry_authorized
      ~(ledger : unit -> Keeper_model_input_ledger.t option)
      ~(last_request : unit -> Keeper_model_input_ledger.request option)
      ~marks
      ~(evict : Keeper_carried_range.step -> bool)
      ~hold_front
      ~(halve : first_atom:int -> atom_count:int -> retry:int -> bool)
      ~(last_resort : retry:int -> bool)
      ~(on_retry : retry:int -> eviction_retry -> unit)
      ~(attempt : unit -> ('ok, Agent_core.Error.t) result)
      ()
  : ('ok, Agent_core.Error.t) result
  =
  let halve_last_request ~retry ~failed ~continue_ =
    match last_request () with
    | None -> failed
    | Some (request : Keeper_model_input_ledger.request) ->
      (match
         Keeper_carried_front.halve
           ~first_atom:request.first_atom
           ~atom_count:request.atom_count
       with
       | None ->
         if last_resort ~retry
         then (
           on_retry ~retry Demoted_newest_atom;
           continue_ ())
         else failed
       | Some first_atom ->
         if halve ~first_atom ~atom_count:request.atom_count ~retry
         then (
           on_retry ~retry (Halved_range { first_atom; atom_count = request.atom_count });
           continue_ ())
         else failed)
  in
  let rec go ~retry =
    match attempt () with
    | Ok _ as ok -> ok
    | Error error as failed ->
      if not (refusal_evicts error && same_run_retry_authorized ())
      then failed
      else (
        let retry = retry + 1 in
        let continue_ () = go ~retry in
        match ledger () with
        | Some ledger ->
          (match Keeper_carried_range.after_overflow ~marks ledger with
           | Keeper_carried_range.Evicted { first_atom; front_digest; _ } as step ->
             (* Another candidate may have moved this turn's front beyond
                this ledger's blocks. Evicting one of those blocks would
                resend the same carried range. Halve the actual request. *)
             let advances_request =
               match last_request () with
               | Some request -> first_atom > request.Keeper_model_input_ledger.first_atom
               | None -> true
             in
             if not advances_request
             then halve_last_request ~retry ~failed ~continue_
             else if evict step
             then (
               hold_front
                 { Keeper_carried_front.first_atom
                 ; front_digest
                 ; source = Keeper_carried_front.Evicted_after_refusal { retry }
                 };
               on_retry ~retry (Evicted_blocks step);
               continue_ ())
             else failed
           | Keeper_carried_range.Unchanged _ -> halve_last_request ~retry ~failed ~continue_)
        | None -> halve_last_request ~retry ~failed ~continue_)
  in
  go ~retry:0
;;

(* One halving after a refusal, answering whether the retry carries a
   strictly later front. [first_atom] is the halved position, after the front
   the refused request carried; [digest_at] is the lookup over the history
   that request was composed from, which the retry composes from again.
   - No digest at [first_atom]: nothing names the new front. [false].
   The seed is held whether the pair's ledger moves or not: it may predate
   this position, or be absent. The composition reads the held position on
   every candidate, so the next request advances in all three cases. *)
let halve_front ~digest_at ~move_ledger ~hold ~first_atom ~retry =
  match Option.bind digest_at (fun digest_at -> digest_at first_atom) with
  | None -> false
  | Some front_digest ->
    (* The ledger may have nothing to move, while halving still succeeds by
       holding this front for the next attempt (RFC section 10.3). *)
    let (_ : bool) = move_ledger ~first_atom ~front_digest in
    hold
      { Keeper_carried_front.first_atom
      ; front_digest
      ; source = Keeper_carried_front.Halved_after_refusal { retry }
      };
    true
;;

(** Same as [run_try_provider], except a refusal that says the request
    outgrew its carrier moves the carried front and retries the SAME
    candidate, before returning to the caller, which still owns
    declared-lane candidate rotation and cascade fallback for every other
    error and for a refusal that survives every move. The front the retry
    composes from is the ledger's after the eviction, or, before any usage
    on this pair, the halved range, which the turn holds for every
    candidate the lane walks to. *)
(* The marks, judged once per candidate turn before its first composition
   (RFC keeper-context-window-in-tokens §10.5): above the high-water mark the
   oldest blocks leave until the projected total is under the low-water mark,
   and every request of the turn composes from that one front. Without marks,
   only a refusal moves the front. *)
let evict_at_turn_boundary ~keeper_name ~runtime_id ~context_marks ledger =
  match context_marks with
  | None -> ()
  | Some marks ->
    (match !ledger with
     | None -> ()
     | Some current ->
       let projected, step = Keeper_carried_range.apply_turn_boundary ~marks current in
       ledger := Some projected;
       (match step with
        | Keeper_carried_range.Unchanged _ -> ()
        | Keeper_carried_range.Evicted _ ->
          Log.Keeper.info
            ~keeper_name
            "model input carried range evicted runtime=%s %s"
            runtime_id
            (Yojson.Safe.to_string (Keeper_carried_range.step_to_json step))))
;;

let run_try_provider_with_carried_range_eviction
      ?continuation_checkpoint
      (ctx : try_provider_ctx)
      candidate
  =
  let state = new_attempt_state ctx in
  if Option.is_none ctx.continuity then
    evict_at_turn_boundary
      ~keeper_name:ctx.keeper_name ~runtime_id:ctx.runtime_id
      ~context_marks:ctx.context_marks state.ledger;
  match ctx.recovery_view, ctx.continuity with
  | Some _, _ | None, Some _ ->
    (* The validated semantic view owns retained source obligations. Retrying
       the same view with a shorter range cannot recover it. Final serialized
       request admission still enforces the request-body cap. *)
    run_try_provider_attempt ?continuation_checkpoint ~state ctx candidate
  | None, None ->
    (* An uncapped runtime retries like any other. #36817 kept such a
       runtime out of the token halving because that walk invented a seed
       from a declared window and ran 18 refusals to zero; this walk moves a
       position on the atom axis, stops at a single atom, and without it a
       history that outgrew the provider would be refused every turn with
       nothing declared to move the front. *)
    let last_resort_used = ref false in
    let checkpoint_after = ref None in
    let success_sample = ref None in
    let result =
      carried_range_eviction_sequence
        ~same_run_retry_authorized:(fun () ->
          same_run_retry_allowed ctx.checkpoint_progress)
        ~ledger:(fun () -> !(state.ledger))
        ~last_request:(fun () ->
          Option.map (fun (sent : sent_request) -> sent.request) !(state.last_request))
        ~marks:ctx.context_marks
        ~hold_front:ctx.hold_carried_front
        ~evict:(function
          | Keeper_carried_range.Evicted { first_atom; front_digest; _ } ->
            move_ledger_front state.ledger ~first_atom ~front_digest
          | Keeper_carried_range.Unchanged _ -> false)
        ~halve:(fun ~first_atom ~atom_count:_ ~retry ->
          (* With a ledger, the move cuts through its one block and the
             blocks restart from the new front, and that ledger is this
             candidate's; without one, the halved seed is what the next
             composition reads, on this candidate and on every later one the
             lane walks to in this turn. *)
          halve_front
            ~digest_at:
              (Option.map (fun (sent : sent_request) -> sent.digest_at) !(state.last_request))
            ~move_ledger:
              (move_ledger_front state.ledger)
            ~hold:ctx.hold_carried_front
            ~first_atom
            ~retry)
        ~last_resort:(fun ~retry:_ ->
          (* Once per attempt, and only when the current turn carries a tool
             result the store could hold; the composition consumes the arm
             on its next request. *)
          if !last_resort_used
          then false
          else (
            match !(state.last_resort_probe) with
            | Some probe when probe () ->
              last_resort_used := true;
              state.last_resort_armed := true;
              true
            | Some _ | None -> false))
        ~on_retry:(fun ~retry decision ->
          let decision = eviction_retry_to_json decision in
          emit_carried_range_retry_manifest ctx ~retry decision;
          Log.Keeper.info
            ~keeper_name:ctx.keeper_name
            "model input carried range retry runtime=%s retry=%d %s"
            ctx.runtime_id
            retry
            (Yojson.Safe.to_string (`Assoc decision)))
        ~attempt:(fun () ->
          let attempt_result, attempt_checkpoint_after, attempt_success_sample =
            run_try_provider_attempt ?continuation_checkpoint ~state ctx candidate
          in
          checkpoint_after := attempt_checkpoint_after;
          success_sample := attempt_success_sample;
          attempt_result)
        ()
    in
    result, !checkpoint_after, !success_sample
;;

let run_try_provider ?continuation_checkpoint ctx candidate =
  run_try_provider_attempt ?continuation_checkpoint ~state:(new_attempt_state ctx) ctx candidate
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
      | Keeper_internal_error.Official_client_recovery_required _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      | Keeper_internal_error.Host_stopped_turn _
      | Keeper_internal_error.Runtime_connection_closed _
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
   worth a second attempt only when thinking was on and this candidate's wire
   can be told to stop. The second half is not rhetorical: some rows declare a
   thinking control that has no off state, and a categorical effort row whose
   ladder omits the off value cannot spell the disable at all. Which surfaces
   those are is catalog data, recorded in agent_core's
   docs/design/provider-reasoning-dialects.md; the decision here reads the
   typed answer. Attempting the retry on such a row spends the turn on a
   request refused before dispatch, and on a lane with one candidate there is
   nothing to rotate to (#36972).
   Dropping the rejected response is owed either way: accept judged it
   unusable, and a checkpoint that keeps it feeds it back as input on every
   later turn.

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

let truncation_recovery ~enable_thinking ~thinking_can_be_disabled ~result ~checkpoint =
  match result, checkpoint with
  | Error error, Some checkpoint when max_tokens_truncation_error error -> (
    match checkpoint_before_incomplete_response checkpoint with
    | None -> Recovery_not_applicable
    | Some cut ->
      if thinking_was_enabled enable_thinking && thinking_can_be_disabled
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

(* Asked of the request the retry would actually send, not of an approximation
   of it: the same candidate, effort stripped, thinking off.

   [Complete_common.validate_all] is the admission every request meets on its
   way out ([Complete.complete], [Complete_sync], [Complete_stream] all begin
   there), and it routes the thinking question by provider kind, each kind to
   the rule that actually governs it. A narrower predicate would answer for
   some kinds and guess for the rest: read on its own,
   [thinking_control_request_rejection] calls a row whose thinking control
   lives on a separate capability axis unable to disable, when that wire turns
   thinking off by sending no thinking field at all. *)
let retry_without_thinking_admitted (candidate : Runtime_candidate.t) =
  let retry_cfg =
    { (Runtime_candidate.provider_cfg (candidate_without_reasoning_effort candidate)) with
      Llm_provider.Provider_config.enable_thinking = Some false
    ; preserve_thinking = Some false
    }
  in
  Result.is_ok (Llm_provider.Complete_common.validate_all retry_cfg)
;;

let run_try_provider_with_truncation_recovery
      ?continuation_checkpoint
      (ctx : try_provider_ctx)
      candidate
  =
  let first_result, checkpoint_after, success_sample =
    run_try_provider_with_carried_range_eviction ?continuation_checkpoint ctx candidate
  in
  let thinking_can_be_disabled = retry_without_thinking_admitted candidate in
  match
    truncation_recovery
      ~enable_thinking:ctx.enable_thinking
      ~thinking_can_be_disabled
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
           ; ( "thinking"
             , `String
                 (if thinking_can_be_disabled
                  then "already_disabled"
                  else "cannot_be_disabled") )
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
  let retry_without_thinking_admitted = retry_without_thinking_admitted
  let memoize_message_measurement = memoize_message_measurement
  let carried_front = carried_front
  let move_ledger_front = move_ledger_front
  let evict_at_turn_boundary = evict_at_turn_boundary
  let halve_front = halve_front
  let message_measurement_hash = Agent_core.Types.Message_value.hash
  let compose_carried_model_input = compose_carried_model_input
  let request_view = request_view
  let last_resort_demotes = last_resort_demotes
  let offload_model_input_cpu = offload_model_input_cpu
end
