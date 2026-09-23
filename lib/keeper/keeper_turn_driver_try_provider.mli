(** Extracted provider-attempt runner for keeper runtime turns. *)

(** A reading of the keeper's live in-turn progress signal (#28417).

    What the stall decision needs, read by the caller so this module decides
    without depending on [Keeper_registry] or on the approval registry. *)
type provider_progress_sample =
  { last_progress_at : float
        (** Unix timestamp of the most recent in-turn progress signal. *)
  ; active_tool_count : int
        (** Tools issued but not yet completed; non-zero means work in
            flight, not a stall. *)
  ; awaiting_approval : bool
        (** Whether a call from this keeper is parked at the approval gate.

            Held calls raise neither signal above: the gate runs at
            [pre_tool_use] and the event that raises [active_tool_count] is
            published after it. So a keeper waiting on a person reads as a
            provider that stopped answering, and the attempt is cancelled and
            filed against the provider. The wait carries its own bound, so
            excluding it here leaves nothing unbounded. *)
  }

(** What one dispatch's checkpoints have recorded so far. It only moves
    forward, in this order.
    - [No_checkpoint_stage]: AGENT_CORE has not reached a checkpoint stage, so
      the agent state is as the dispatch began and another candidate may take
      the same run.
    - [Checkpoint_stage_reached]: a stage was reached, whether or not its save
      succeeded. The attempt may hold effects, so no same-run retry.
    - [Tool_results_saved]: a stage written after tools ran
      ([After_tool_results_appended], [After_context_injection]) was saved. A
      chat operation resumed from its latest checkpoint does not run those
      tools again (RFC last-path-resumes-after-progress §3.2). *)
type checkpoint_progress =
  | No_checkpoint_stage
  | Checkpoint_stage_reached
  | Tool_results_saved

type continuity
(** A snapshot verified against the dispatch's original checkpoint. *)

val without_snapshot : continuity
(** No snapshot to summarize with: none is saved, or the saved one does not
    fit this history or cannot be used ({!continuity_for_request}). The request
    starts at the seed -- the working ledger's front, or the range the newest
    turn record joined to a response -- when one is valid for this history
    ({!Keeper_carried_front.for_history}), and otherwise at the turn's own
    boundary ({!Keeper_carried_front.Turn_start}). A size refusal of the seed
    range is answered once from that boundary ({!seed_refusal_sequence}). *)

type continuity_choice =
  | Chose_no_point
      (** The turn had no Librarian point to start from
          ({!without_snapshot}). *)
  | Chose_a_librarian_point
      (** The turn started at a snapshot's end or at the Librarian's read
          position. *)

val continuity_choice : continuity -> continuity_choice
(** Which of the two a continuity is, for a caller that records what a
    request started from
    ({!Keeper_official_client_host.continuity_observation_input}). The
    constructors stay in, so no caller can build a continuity that was never
    checked against this dispatch's checkpoint. *)

val absorbed_history :
  trace_id:string ->
  messages:Agent_core.Types.message list ->
  Keeper_librarian_progress.t ->
  (int * continuity) option
(** The Librarian's durable position as the front of the request, with the
    exclusive end atom it stands at: the atoms before it are read into memory
    and are not sent again, and no summary stands in for them. [Some] only
    when the position names [trace_id] and the atom before it opens with the
    message the position recorded, so a position from another trace or
    another history generation is [None]. Taken when no saved continuity
    snapshot fits the history: none is saved, it no longer fits, or it cannot
    be used ({!continuity_for_request}) (RFC keeper-context-window-in-tokens
    section 13.6). *)

val completed_history_end :
  trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  messages:Agent_core.Types.message list -> (int, Librarian_continuity_snapshot.error) result
(** The last verified completed atom endpoint. An attempt seed is not proof that
    resumed work completed; callers retain original bodies when no proof exists. *)

val turn_start :
  config:Workspace.config -> keeper_name:string -> trace_id:string ->
  messages:Agent_core.Types.message list -> Keeper_carried_front.turn_start
(** Where a request with no absorbed point starts (RFC
    keeper-context-window-in-tokens §13.4): {!completed_history_end} read from
    the keeper's turn-boundary store, [Turn_boundary 0] when the history has
    no completed turn. A store this process cannot read, or a boundary the
    history in hand does not match, is logged and answered
    [Turn_boundary_unknown]: the request then opens on the newest atom alone
    and its origin says so, rather than on the whole history. *)

val prepare_continuity :
  trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  messages:Agent_core.Types.message list ->
  Librarian_continuity_snapshot.t ->
  (continuity, Librarian_continuity_snapshot.error) result

val validate_continuity :
  messages:Agent_core.Types.message list -> continuity -> (unit, Agent_core.Error.t) result
(** Check immutable covered messages again before each request. No source bytes
    are reserialized; a changed prefix refuses the request. The baseline it
    compares against belongs to one attempt ({!continuity_for_attempt}), so
    what it answers is whether that attempt's list changed in flight. *)

val continuity_for_attempt :
  messages:Agent_core.Types.message list -> continuity -> continuity
(** The turn's choice with the baseline {!validate_continuity} compares
    against taken from [messages], the list one attempt starts from. Which
    continuity the turn chose does not change; only the bytes the
    dispatch-time check holds it to.

    A candidate can be handed another rendering of the same history — a
    runtime that cannot see an image gets a reading of it in its place, for
    that candidate alone (RFC-0265 media degrade). Held to the checkpoint's
    bytes, such a candidate was refused on every request (#37812). Whether
    the choice fits this history at all is a question
    {!continuity_for_request} already answered, against the history. *)

(** Where the chosen continuity puts a lane's range, for the official-client
    lanes that cut their own start seed. *)
type librarian_position =
  | No_position
      (** No absorbed point: no snapshot or position fits this history
          ({!without_snapshot}). The lane's seed, its own cut, or the turn
          start decides. *)
  | Librarian_snapshot of Librarian_continuity_snapshot.t
      (** A snapshot fits: the atoms before its end are summarised by its
          working state, which is carried in their place. *)
  | Librarian_progress of { end_atom : int }
      (** No snapshot fits, and the Librarian's read position does: the atoms
          before [end_atom] are in the keeper's memory, and nothing is
          carried in their place. *)

val librarian_position :
  messages:Agent_core.Types.message list ->
  continuity ->
  (librarian_position, Agent_core.Error.t) result
(** The continuity the turn chose ({!continuity_for_request}) as a position
    in [messages], the list a lane is about to cut. [Error] when that list no
    longer holds what the choice covered ({!validate_continuity}), the same
    error that refuses an Agent Core request; the lane refuses its request
    with it. *)

val working_state_text : Librarian_continuity_snapshot.t -> string
(** The text a request carries in place of the atoms a fitting snapshot
    covers: its working state under a label saying it is a summary to use as
    context, not new instructions. Every lane that carries a working state
    sends this text. *)

val continuity_for_request :
  keeper_name:string ->
  trace_id:string ->
  messages:Agent_core.Types.message list ->
  snapshot:(Librarian_continuity_snapshot.t option, string) result ->
  lines:
    (unit ->
     ((int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list,
      string)
     result) ->
  progress:(unit -> (Keeper_librarian_progress.t option, string) result) ->
  continuity
(** Where a request starts (RFC keeper-context-window-in-tokens §13.4, §13.6):
    a [snapshot] that fits these messages, else the Librarian's durable
    [progress] when it is a place in this history ({!absorbed_history}), else
    {!without_snapshot}. There is no refusal: a snapshot that cannot be read,
    whose [lines] cannot be read, or whose covered bytes changed is one that
    does not fit, and is logged as a warning naming what is wrong (#37762). A
    turn needs no snapshot to go out, and a refused turn ran no Librarian
    round, so a snapshot whose covered bytes changed was never written again.
    An unreadable snapshot file or boundary log stops the Librarian's
    continuity pass too, so it stays until the file is fixed.
    A snapshot the Librarian is rewriting from atom 0 is not used until its
    end reaches its catch-up target
    ([Librarian_continuity_snapshot.t.catch_up_end_atom]); until then the
    request starts as it would with no snapshot, so the rewrite never moves
    the start back.
    [lines] is read only when a snapshot is saved. It writes
    {!choose_continuity}'s notes to [keeper_name]'s log. *)

(** What {!choose_continuity} passed over on the way to its choice, in the
    order it met it. *)
type continuity_note =
  | Snapshot_unusable of { why : string }
      (** A saved snapshot could not be used at all: unreadable, its boundary
          log unreadable, or its covered bytes changed. A warning. *)
  | Progress_unreadable of { why : string; detail : string }
      (** No snapshot fits, and the Librarian's progress file could not be
          read. A warning. *)
  | Started_at_read_position of { why : string; end_atom : int }
  | Started_at_turn_boundary of { why : string }

val choose_continuity :
  trace_id:string ->
  messages:Agent_core.Types.message list ->
  snapshot:(Librarian_continuity_snapshot.t option, string) result ->
  lines:
    (unit ->
     ((int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list,
      string)
     result) ->
  progress:(unit -> (Keeper_librarian_progress.t option, string) result) ->
  continuity * continuity_note list
(** {!continuity_for_request}'s choice, with what it passed over returned
    instead of logged: an empty list when a snapshot fits. *)

val log_continuity_note : keeper_name:string -> continuity_note -> unit

val read_keeper_continuity :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  messages:Agent_core.Types.message list ->
  continuity * continuity_note list
(** {!choose_continuity} over [keeper_name]'s own snapshot, turn-boundary
    log and Librarian progress file. The turn driver logs the notes; the
    next-request forecast, which only looks, does not. *)

(** Where a request's carried range opens (RFC keeper-context-window-in-tokens
    §13.4, §13.6). *)
type range_start =
  | From_snapshot of Librarian_continuity_snapshot.t
      (** A snapshot fits: its working state rides in place of the atoms
          before its end. *)
  | From_read_position of { end_atom : int }
      (** No snapshot fits and the Librarian's read position does: the atoms
          before [end_atom] are not sent, and nothing stands in for them. *)
  | From_seed of Keeper_carried_front.seed
      (** No Librarian point, and a seed this history opens with the same
          message ({!Keeper_carried_front.for_history}). *)
  | From_turn_boundary of Keeper_carried_front.turn_start
      (** No Librarian point and no seed that holds: this turn's own atoms,
          or the newest atom alone when the boundary is unknown. *)

type start_choice =
  { start : range_start
  ; outlived_seed : (Keeper_carried_front.seed * Keeper_carried_front.dropped_front) option
        (** A seed this history does not hold, dropped with the reason. *)
  }

val choose_range_start :
  continuity:continuity option ->
  front:Keeper_carried_front.seed option ->
  history_digest_at:(int -> string option) ->
  turn_boundary:Keeper_carried_front.turn_start ->
  start_choice
(** The one rule for where a request starts: a snapshot that fits, else the
    Librarian's read position, else [front] when [history_digest_at] opens
    its index with the same message, else [turn_boundary]. [continuity] is
    [None] for a request with no trace or one composed from a recovery view,
    and is then read as {!without_snapshot}. Pure: the caller reads the
    files. The turn's composition and {!Keeper_next_request_forecast} both
    call it, so the forecast shows the start the request will have. *)

val range_start_origin : range_start -> Keeper_carried_front.origin

val project_range_start :
  measure_message_bytes:(Agent_core.Types.message -> int) ->
  atom_count:int ->
  range_start ->
  Agent_core.Types.message list ->
  Runtime_model_input_tail_window.projection * int
(** The range [start] opens over [messages] of [atom_count] atoms and its
    bytes as [measure_message_bytes] counts them. A snapshot's working state
    ({!working_state_text}) rides ahead of the atoms it does not cover. *)

type try_provider_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; context_marks : Runtime_schema.context_marks option
        (** The marks the carried range is judged against once per candidate
            turn, before its first composition (RFC
            keeper-context-window-in-tokens §10.5), as the binding declares
            them; [None] leaves eviction to a refusal. *)
  ; carried_front_seed : unit -> Keeper_carried_front.seed_read
        (** The durable seed, read only when neither the pair's ledger nor a
            refusal in this turn supplies the front. *)
  ; continuity : continuity option
  ; input_policy : Keeper_input_policy.t
  ; turn_boundary : Keeper_carried_front.turn_start
  ; carried_front_after_refusal : unit -> Keeper_carried_front.seed option
        (** The latest refusal's front, shared by every Agent Core candidate
            of this turn. A valid later front takes precedence over the
            candidate's ledger, including when that ledger predates it. *)
  ; hold_carried_front : Keeper_carried_front.seed -> unit
        (** Keeps a front moved by either halving or block eviction after a
            refusal. It names an atom of the shared checkpoint history. *)
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; goal_blocks : Agent_core.Types.content_block list option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; initial_messages : Agent_core.Types.message list
  ; model_input_projection : Agent_core.Agent.model_input_projection option
  ; recovery_view : Keeper_recovery_transmission.t option
  ; stream_idle_timeout_s : float
  ; first_event_timeout_s : float
  ; body_timeout_s : float option
  ; provider_call_deadline_sec : float
        (** Seconds a provider attempt may go WITHOUT a progress signal
            before it is cancelled and rotated (#28417 changed this from a
            total-elapsed ceiling). Always set: the operator's value or the
            resolved layer's failsafe floor. *)
  ; provider_progress_probe : (unit -> provider_progress_sample option) option
        (** Reads the keeper's live progress signal. Must not raise; return
            [None] when unavailable, which degrades the deadline to the
            pre-#28417 elapsed ceiling. *)
  ; person_queued_probe : (unit -> bool) option
        (** Reads whether a person's chat operation is queued behind this turn.
            Present only on the autonomous lane; [None] disables first-token-wait
            preemption (RFC-0441 pre-first-token gap). Must not raise. *)
  ; temperature : float option
  ; accept : Agent_core.Types.api_response -> bool
  ; hooks : Agent_core.Hooks.hooks option
  ; approval_gate : Keeper_tool_approval_gate.t option
        (** Holds a tool call for an operator before it runs. Absent means no
            call is held, which is what an autonomous turn wants: nobody is
            watching it to answer. *)
  ; raw_trace : Agent_core.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport_resolved : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
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
  ; sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; on_event : (Agent_core.Types.sse_event -> unit) option
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
        (** Called with the cut the window stage selected over the keeper's
            conversation history, as that stage saw it, and which shape it was
            measured against.

            Two kinds of material in the same request are outside these counts,
            for two different reasons. Pinned extra-system context and the
            synthetic preamble are excluded by rule: {!annotate} classifies
            them [Pinned] every turn because they are re-assembled rather than
            conversed. Anything [ctx.model_input_projection] appends afterwards
            — a pending Gate approval replay, for instance — is excluded only
            because it arrives after this stage has run. That one is ordinary
            conversation, it is persisted, and from the next turn it is counted
            like any other atom; the turn it is appended on undercounts by
            exactly that message and then self-corrects.

            So this is not a decomposition of {!on_request_wire_observation}:
            that one measures the bytes the provider admitted, and those bytes
            cover material these atoms do not.

            Invoked per provider request, and one keeper turn issues many —
            62 and 83 on the two turns this module's window comment measures —
            so the retained value is the last request of the turn, not a
            summary of it. Never invoked when the projection refuses: the turn
            carries a typed budget error instead, and reporting a cut that was
            never dispatched would fabricate evidence. *)
  ; on_response_observed_model_input :
      (Turn_record.response_observed_model_input -> unit) option
        (** Called only when [AfterTurn] joins a typed provider response to the
            exact Agent Core request range that produced it. Later unanswered
            attempts do not replace this fact. *)
  ; event_bus : Agent_core.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

val apply_accept :
  runtime_id:string ->
  accept:(Agent_core.Types.api_response -> bool) ->
  Runtime_agent.run_result ->
  (Runtime_agent.run_result, Agent_core.Error.t) result

val observe_checkpoint_stage :
  checkpoint_progress Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit
(** Marks that a stage was reached. Called before the stage is saved. *)

val observe_checkpoint_saved :
  checkpoint_progress Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit
(** Marks [Tool_results_saved] for a stage written after tools ran. Only the
    owner of the checkpoint sink may call it, and only for a write it made:
    a sink answers [Ok ()] for a write it skipped as well
    ([Keeper_checkpoint_store.Stale_noop], which leaves the canonical
    checkpoint untouched), and a resumed operation would not read the
    checkpoint that write claimed. *)

val observing_checkpoint_sink :
  checkpoint_progress Atomic.t ->
  Agent_core.Agent.checkpoint_sink option ->
  Agent_core.Agent.checkpoint_sink
(** The sink an attempt hands AGENT_CORE: marks the stage, then delegates to
    the caller's sink and returns its answer unread. Saved tool results are
    not marked here — see {!observe_checkpoint_saved}. *)

val same_run_retry_allowed : checkpoint_progress Atomic.t -> bool
(** [true] only at [No_checkpoint_stage]. *)

val tool_results_saved : checkpoint_progress Atomic.t -> bool
(** [true] only at [Tool_results_saved]. *)

type provider_lease_phase =
  | Provider_active_since of float
  | Provider_yielded
(** Invocation-local main-provider lease observation, not tool completion or
    a persisted lifecycle state. *)

val provider_lease_stalled :
  lease_phase:provider_lease_phase
  -> now:float
  -> threshold_sec:float
  -> attempt_started_at:float
  -> permit_wait:Llm_provider.Provider_admission.permit_wait
  -> sample:provider_progress_sample option
  -> bool
(** A yielded main-provider lease cannot be stalled. On reacquisition, the
    no-progress window starts no earlier than that reacquisition, including
    when the asynchronous registry sample is absent or stale. *)

val attempt_stalled :
  now:float
  -> threshold_sec:float
  -> attempt_started_at:float
  -> permit_wait:Llm_provider.Provider_admission.permit_wait
  -> sample:provider_progress_sample option
  -> bool
(** The stall verdict for a running provider attempt (#28417), pure in its
    inputs so it is testable without Eio or a registry.

    Never stalled while [permit_wait] is [Waiting_for_permit]: a bounded wait
    for the binding's admission permit is queueing with a deadline of its
    own, and Agent Core writes the cell for no other kind of wait, so
    standing down for it leaves nothing unbounded and lets the admission
    bound alone end it, as [Queue]. [Wait_settled_at] is the instant that
    wait ended, and the verdict counts from it: the attempt's own budgets
    start there, so the silence that is a stall is the silence after it.

    With a [sample], the attempt is stalled when no tool is in flight AND the
    last progress signal is older than [threshold_sec]. A tool call that runs
    for minutes refreshes no progress signal while it runs, so tools in
    flight count as work.

    With [sample = None] (probe absent, or no live turn observation), the
    verdict falls back to elapsed time since [attempt_started_at] — the
    pre-#28417 behaviour, so a lost progress signal cannot silently disable
    enforcement. *)

val preempt_pre_first_token : first_event_seen:bool -> person_queued:bool -> bool
(** First-token-wait preemption verdict (RFC-0441 pre-first-token gap), pure in
    its inputs. [true] only when the provider has produced no streaming event
    yet ([not first_event_seen]) and a person's chat operation is queued. Once
    the first event arrives the tool-boundary yield owns the handover, so this
    is [false]; with no one queued it is [false] and the attempt keeps its full
    first-event/idle bounds. *)

val default_context_overflow_shrink_capacity : capacity:int -> int
(** The shared provider-oracle target for one ordinary shrink step. The
    runtime-specific caller may clamp this target further to structural
    message boundaries. *)

val context_overflow_shrink_sequence :
  ?shrink_capacity:
    (capacity:int -> default_capacity:int -> int) ->
  ?final_shrink_capacity:(capacity:int -> int option) ->
  starting_capacity:int ->
  same_run_retry_authorized:(unit -> bool) ->
  shrink_admits_history:(capacity:int -> bool) ->
  on_shrink_retry:
    (shrink_attempt:int ->
     previous_capacity:int ->
     capacity:int ->
     unit) ->
  attempt:(capacity:int -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** Provider-oracle retry policy of the official-client runtimes, whose
    seed history is cut against a declared prompt byte cap; the capacity is
    in bytes. The Agent Core lane answers the same refusal by moving its
    carried front ({!run_try_provider_with_carried_range_eviction}).
    [default_capacity] is the policy's ordinary halved value;
    a custom [shrink_capacity] can replace only exceptional starting values
    without copying the shared divisor. The walk carries no attempt count:
    it ends where no strictly smaller view exists. [final_shrink_capacity]
    names a measured structural floor; once the ordinary target would reach
    or pass it, the floor itself is attempted, and its refusal ends the
    sequence. A custom value that does not strictly decrease
    [capacity] terminates the sequence without another provider attempt.

    [shrink_admits_history] answers whether a proposed capacity leaves room
    for any conversation history once the caller's non-history reserve is
    charged. A [false] verdict terminates the sequence with the failure in
    hand rather than spending an attempt on a size that cannot succeed: the
    reserve does not shrink with the capacity, so a smaller window refuses
    for the same reason, one size lower. *)

val run_try_provider :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option

type eviction_retry =
  | Evicted_blocks of Keeper_carried_range.step
      (** The oldest blocks of the pair's ledger left. *)
  | Halved_range of
      { first_atom : int
      ; atom_count : int
      }
      (** No block structure to walk: the range halved toward the newest
          atom. *)

val carried_range_eviction_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  ledger:(unit -> Keeper_model_input_ledger.t option) ->
  last_request:(unit -> Keeper_model_input_ledger.request option) ->
  marks:Runtime_schema.context_marks option ->
  evict:(Keeper_carried_range.step -> bool) ->
  hold_front:(Keeper_carried_front.seed -> unit) ->
  halve:(first_atom:int -> atom_count:int -> retry:int -> bool) ->
  on_retry:(retry:int -> eviction_retry -> unit) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The Agent Core lane's retry policy over an injected [attempt] (RFC
    keeper-context-window-in-tokens §10.5). A provider context overflow or a
    size refusal on the byte axis is answered from the pair's ledger with
    {!Keeper_carried_range.after_overflow}; [evict] applies a step beyond the
    refused request's front and [hold_front] shares it with later candidates.
    When the ledger has no block structure ahead of the actual request, no
    usage counted yet or a single block, [last_request]'s range halves
    toward the newest atom through [halve], which answers [false] when it
    cannot name the halved front by its opening message and so ends the
    sequence with the refusal in hand, as a refused single atom does
    ({!current_turn_demotion_sequence} answers what is left). Every retry follows a move
    that [evict] or [halve] reported, so the sequence never resends the range
    that was refused. Every other error ends it at once, as does a refusal
    once [same_run_retry_authorized] is [false]. *)

val seed_refusal_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  refused_range:(unit -> (Keeper_carried_front.origin * int) option) ->
  turn_start_front:(unit -> Keeper_carried_front.seed option) ->
  hold_front:(Keeper_carried_front.seed -> unit) ->
  on_turn_start:(Agent_core.Error.t -> Keeper_carried_front.seed -> unit) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The retry policy of a turn with no Librarian point ({!without_snapshot}),
    over an injected [attempt] (RFC keeper-context-window-in-tokens §13.4).
    When [attempt] fails with a typed size refusal or a refusal whose
    reason agent core does not model ([Unknown_invalid_request], which is how
    live size refusals arrive), [refused_range] reports that the refused range
    opened on a seed ({!Keeper_carried_front.Carried}) at its first atom,
    [turn_start_front] names the turn boundary strictly after that atom
    ({!Keeper_carried_front.Turn_start_after_seed_refusal}), and
    [same_run_retry_authorized] holds, the boundary is given to [hold_front]
    as the turn's front, [on_turn_start] is told, and [attempt] runs once
    more; its result is returned as it is. Every other failure is returned
    at once, so a candidate that already opens at the held boundary is not
    asked twice. The range is never halved: an accepted boundary request is
    what the ledger records, so the next turn's seed is that boundary. *)

type current_turn_results =
  | Current_turn_verbatim
      (** The ordinary demotion boundary: the current turn's tool results go
          as they are. *)
  | Current_turn_demoted of { refused_atom_count : int }
      (** A request carrying [refused_atom_count] atoms was refused for size:
          every tool result from the turn boundary (the newest atom alone
          when the boundary is unknown) up to [refused_atom_count] goes as its
          externalized marker (#28845). Earlier turns go as the policy
          composes them, and atoms appended after the refused ones, the
          results a resent attempt produces, go as they are. *)

val current_turn_demotion_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  demotable:(unit -> int option) ->
  demote:(Agent_core.Error.t -> refused_atom_count:int -> unit) ->
  first:(unit -> ('ok, Agent_core.Error.t) result) ->
  resend:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The last answer to a size refusal, on every continuity (RFC
    keeper-context-window-in-tokens §10.4, §13.9). When [first] fails with a
    refusal {!carried_range_eviction_sequence} would move the front for,
    [same_run_retry_authorized] holds, and [demotable] names the refused
    request's atom count because demoting this turn's tool results in it
    would carry fewer bytes, [demote] is told and [resend] runs once; its
    result is returned as it is. The range is not narrowed. With nothing to
    demote, and on every other failure, the failure is returned at once. *)

val run_try_provider_with_carried_range_eviction :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** {!run_try_provider} under {!carried_range_eviction_sequence}, after the
    marks are judged against the pair's ledger once for the turn: the
    eviction moves the pair's ledger front, the halving holds a seed for the
    rest of this attempt, and each retry is recorded on the runtime
    manifest. A turn with no Librarian point runs under
    {!seed_refusal_sequence} instead, and a turn with an absorbed point runs
    one attempt. Whatever the continuity, a size refusal left after that is
    answered by {!current_turn_demotion_sequence} on the same candidate,
    when the Keeper is offered the artifact reader the markers name. A
    recovery view runs one attempt. *)

val run_try_provider_with_truncation_recovery :
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** Run the carried-range eviction first. When the accepted
    boundary instead reports a typed [MaxTokens] truncation, remove only that
    incomplete Assistant message from the post-run checkpoint and continue the
    same candidate once with thinking disabled. No new User message is added,
    so already-recorded tool results remain the continuation authority. *)

val accept_rejected_error :
  runtime_id:string ->
  response:Agent_core.Types.api_response ->
  Agent_core.Error.t

type composed =
  { planned : Keeper_model_input_demotion.plan_result
  ; projection : Runtime_model_input_tail_window.projection
  ; transmitted_bytes : int
        (** Pinned messages, the carried atoms and the preamble, as the
            durable encoder counts them, reasoning the wire deletes included;
            excludes the reservation. *)
  ; history_atom_count : int  (** Atoms in the whole history. *)
  ; origin : Keeper_carried_front.origin
  ; outlived_seed : (Keeper_carried_front.seed * Keeper_carried_front.dropped_front) option
        (** A front this history does not open with the same message, dropped
            by {!Keeper_carried_front.for_history} with the reason; the
            request started over. *)
  ; demote_from : int
        (** The first atom the demotion may touch: 0, or this turn's first
            atom under {!Current_turn_demoted} when the policy keeps earlier
            turns verbatim. *)
  ; demote_before : int
        (** The boundary the demotion applied: 0 when demotion is off, the
            refused request's atom count under {!Current_turn_demoted}. *)
  }
(** One request as {!For_testing.compose_carried_model_input} composes it
    (RFC keeper-context-window-in-tokens §10.4): RFC-0363 demotion over the
    atoms older than [demote_before], joined under {!Current_turn_demoted} by
    this turn's atoms up to the refused request's end, then the carried
    range from where {!choose_range_start} opens it (§13.4, §13.6). Nothing
    here measures the request against a limit. *)

type request_view =
  { composed : composed
  ; carried : Agent_core.Types.message list
        (** The composed messages with their demotions materialized: what the
            ledger and the turn record count, in atoms of the checkpoint
            history. *)
  ; wire :
      ( Agent_core.Types.message list
        , Agent_core.Llm_provider.Reasoning_history_projection.error )
        result
        (** The dialect's reasoning projection over [carried] alone, or why
            it declined; [carried] itself is then handed over, and the
            backend, running the same projection, refuses the request with
            its typed error. *)
  }
(** One request as {!For_testing.request_view} views it: composed in the
    durable vocabulary first, projected for the wire afterwards. The order
    keeps atom positions a property of the history rather than of the
    dialect, so a front measured on one runtime names the same atom on every
    runtime whatever reasoning each replays or deletes. *)

module For_testing : sig
  val observe_provider_lease :
    now:(unit -> float) -> on_yield:(unit -> unit) option ->
    on_resume:(unit -> unit) option ->
    provider_lease_phase Atomic.t * (unit -> unit) * (unit -> unit)

  val checkpoint_before_incomplete_response :
    Agent_core.Checkpoint.t -> Agent_core.Checkpoint.t option

  val max_tokens_truncation_error : Agent_core.Error.t -> bool

  (** What a max-tokens rejection owes the checkpoint. Retrying without
      thinking is a remedy for a budget spent thinking and applies only when
      thinking was on and the candidate's wire can be told to stop; dropping
      the rejected response is owed either way, because accept judged it
      unusable and a checkpoint that keeps it feeds it back as input on every
      later turn. *)
  type truncation_recovery =
    | Recovery_not_applicable
    | Retry_without_thinking of Agent_core.Checkpoint.t
    | Drop_rejected_response of Agent_core.Checkpoint.t

  val truncation_recovery :
    enable_thinking:bool option ->
    thinking_can_be_disabled:bool ->
    result:(Runtime_agent.run_result, Agent_core.Error.t) result ->
    checkpoint:Agent_core.Checkpoint.t option ->
    truncation_recovery

  (** Write the cut checkpoint through the keeper's sink under
      [After_rejected_response_dropped]; [Ok ()] with no sink. *)
  val persist_dropped_response
    :  checkpoint_sink:Agent_core.Agent.checkpoint_sink option
    -> now:float
    -> Agent_core.Checkpoint.t
    -> (unit, string) result

  (** The candidate a no-thinking truncation retry dispatches to: identical
      but for [reasoning_effort = None], because the wires that admit effort
      reject it with thinking disabled. *)
  val candidate_without_reasoning_effort : Runtime_candidate.t -> Runtime_candidate.t

  (** Whether the no-thinking retry would be admitted on this candidate, asked
      of the request it would send and answered by the admission every request
      meets ([Complete_common.validate_all]). This is what
      {!truncation_recovery} reads as [thinking_can_be_disabled]. *)
  val retry_without_thinking_admitted : Runtime_candidate.t -> bool

  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val memoize_message_measurement :
    (Agent_core.Types.message -> int) -> Agent_core.Types.message -> int

  val message_measurement_hash : Agent_core.Types.message -> int

  val compose_carried_model_input :
    ?input_policy:Keeper_input_policy.t ->
    ?continuity:continuity ->
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    front:Keeper_carried_front.seed option ->
    history_digest_at:(int -> string option) ->
    current_turn_results:current_turn_results ->
    base_path:string ->
    demote_before:int ->
    turn_boundary:Keeper_carried_front.turn_start ->
    Agent_core.Types.message list ->
    composed

  val request_view :
    ?input_policy:Keeper_input_policy.t ->
    ?continuity:continuity ->
    provider_config:Agent_core.Llm_provider.Provider_config.t ->
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    front:Keeper_carried_front.seed option ->
    history_digest_at:(int -> string option) ->
    current_turn_results:current_turn_results ->
    base_path:string ->
    demote_before:int ->
    turn_boundary:Keeper_carried_front.turn_start ->
    materialize:
      (pending:Keeper_model_input_demotion.pending list ->
       Agent_core.Types.message list ->
       Agent_core.Types.message list) ->
    Agent_core.Types.message list ->
    request_view

  val current_turn_demotion : refused:composed -> demoted:composed -> int option
  (** Whether [demoted], the refused range composed under
      {!Current_turn_demoted}, carries fewer bytes than [refused], both
      measured with the plan's placeholders: the refused request's atom count
      when it does, [None] when there is nothing to demote in it. *)

  val carried_front :
    ledger:Keeper_model_input_ledger.t option ref ->
    keeper_name:string ->
    runtime_id:string ->
    session_id:string ->
    digest_at:(int -> string option) ->
    after_refusal:Keeper_carried_front.seed option ->
    cold:(unit -> Keeper_carried_front.seed option) ->
    Keeper_carried_front.seed option * Keeper_model_input_ledger.t option
  (** The front a request composes from, [digest_at] being the lookup over
      the history it composes from: the candidate's working ledger front
      while that history holds the ledger ({!Keeper_model_input_ledger.holds}), advanced
      by a valid later [after_refusal] front. With neither, [cold ()]. A ledger
      that does not hold is returned second; the current table entry is
      independently checked before discarding or adopting it. *)

  val move_ledger_front :
    Keeper_model_input_ledger.t option ref ->
    first_atom:int -> front_digest:string -> bool
  (** Move only the candidate's working value. *)

  val evict_at_turn_boundary :
    keeper_name:string -> runtime_id:string ->
    context_marks:Runtime_schema.context_marks option ->
    Keeper_model_input_ledger.t option ref -> unit
  (** Apply this runtime's declared marks to its candidate's working value. *)

  val halve_front :
    digest_at:(int -> string option) option ->
    move_ledger:(first_atom:int -> front_digest:string -> bool) ->
    hold:(Keeper_carried_front.seed -> unit) ->
    first_atom:int ->
    retry:int ->
    bool
  (** One halving after a refusal: whether the retry carries a strictly
      later front, chosen by {!Keeper_carried_front.halve} on the refused
      request. [false] when [digest_at] has no atom there. Otherwise [hold]
      keeps the seed even if the ledger predates that position and cannot
      move to it; the next composition uses the held front. *)

  val offload_model_input_cpu : (unit -> 'a) -> 'a

end
