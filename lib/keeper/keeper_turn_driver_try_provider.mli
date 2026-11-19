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

(** What one dispatch's checkpoints have recorded so far. Reaching a later
    stage cannot erase classified saves.
    - [No_checkpoint_stage]: AGENT_CORE has not reached a checkpoint stage, so
      the agent state is as the dispatch began and another candidate may take
      the same run.
    - [Checkpoint_stage_reached]: a stage was reached, whether or not its save
      succeeded. The attempt may hold effects, so no same-run retry.
    - [Tool_results_saved]: a stage written after tools ran
      ([After_tool_results_appended], [After_context_injection]) was saved. A
      chat operation resumed from its latest checkpoint does not run those
      tools again (RFC last-path-resumes-after-progress §3.2).
    - [Assistant_checkpoint_saved]: a classified assistant save has occurred;
      any earlier tool/context progress is preserved separately. *)
type checkpoint_progress =
  | No_checkpoint_stage
  | Checkpoint_stage_reached
  | Tool_results_saved of { tool_result_saves : int }
      (** Number of actual [After_tool_results_appended] saves. Context-only
          saves establish retry continuity but do not advance this count. *)
  | Assistant_checkpoint_saved of
      { assistant_saves : int
      ; tool_result_saves : int option
      }
      (** Classified assistant saves, independent of saved tool progress.
          [None] means no tool/context checkpoint was saved; [Some 0] means
          context-only progress. Assistant saves alone cannot authorize a
          tool-result retry. Counts observe actual saves, never sink returns. *)

type continuity
(** A snapshot verified against the dispatch's original checkpoint. *)

val without_snapshot : continuity
(** No snapshot to summarize with: none is saved, or the saved one does not
    fit this history or cannot be used ({!continuity_for_request}). The request
    starts at the seed -- the working ledger's front, or the range the newest
    turn record joined to a response -- when one is valid for this history
    ({!Keeper_carried_front.for_history}), and otherwise at the turn's own
    boundary ({!Keeper_carried_front.Turn_start}). A size refusal of the seed
    range is answered once from that boundary
    ({!turn_boundary_resend_sequence}). *)

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

(** Whether the [Opened] this run wrote comes before this turn's input
    (RFC librarian-lifecycle §4.10, rules 7 and 8). The driver reads where
    this turn began from that line's baseline only for
    [Opened_before_its_input]. *)
type this_turn_opening =
  | Opened_before_its_input
      (** This run put the turn's input into the history after its
          [Opened]: the line's baseline is where the turn began. *)
  | Opened_after_its_input
      (** A resumed checkpoint (native resume, direct resume, HITL) already
          holds this turn's input and maybe its progress, and an earlier run
          closed them. This run's [Opened] is written after them, so its
          baseline names no start: resending from it would leave the turn's
          own request out. *)

type turn_starts =
  { boundary : Keeper_carried_front.turn_start
        (** Where a request with no absorbed point starts (RFC
            keeper-context-window-in-tokens §13.4): the end of the last unit
            of the Keeper's turn log (RFC librarian-call-only-proposes
            §11.2). A log with no line is [Turn_boundary 0]. A log this
            process cannot read, a mark of another trace, or a history shorter
            than the mark is [Turn_boundary_unknown]: a request it decides
            then opens on the newest atom alone and its origin says so,
            rather than on the whole history. *)
  ; this_turn : int option
        (** Where this turn began: the baseline of the log's open [Opened],
            for a run that wrote it before the turn's input
            ({!this_turn_opening}; the driver decides). Rule 8 resends from
            it, and rule 7 bounds the front rule 8 held by it (RFC
            librarian-lifecycle §4.10). When this run's admission line was
            not written, the open [Opened] is the unclosed one of an earlier
            run: its baseline is earlier, so the start comes out earlier,
            never past this turn's input. [None] with no open turn,
            a [Reset] after its [Opened], a baseline of another trace, or a
            history shorter than the baseline. *)
  }

val turn_starts :
  config:Workspace.config -> keeper_name:string -> trace_id:string ->
  messages:Agent_core.Types.message list -> turn_starts
(** Both starts from one read of the turn log's tail, each a count of closed
    messages turned into the atom of [messages] that the next message opens.
    No digest is compared: a purge that rewrites a closed message keeps its
    number (RFC librarian-call-only-proposes §5.6). Reading it logs nothing;
    the request whose range it opens warns
    ({!Keeper_carried_front.warn_range_opens_on_newest_atom}). *)

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
type librarian_position_kind =
  | No_position
      (** No absorbed point: no snapshot or position fits this history
          ({!without_snapshot}). The lane's seed, its own cut, or the turn
          start decides. *)
  | Librarian_snapshot of Librarian_continuity_snapshot.t
      (** A snapshot fits: the represented messages before its end are
          summarised by its working state. Unread exceptions travel separately. *)
  | Librarian_progress of { end_atom : int }
      (** No snapshot fits, and the Librarian's read position does. No working
          state stands in for the prior atoms; unread exceptions are still
          carried independently and are not claimed to be in Memory. *)

type librarian_position =
  { point : librarian_position_kind
  ; unread : Keeper_librarian_request_unread.t
  }
val no_librarian_position : librarian_position
(** No observation was provided: both sources remain unavailable, not empty. *)
val request_unread : continuity -> Keeper_librarian_request_unread.t
(** The original frozen observations, independent of point selection and the
    candidate-specific message baseline. *)

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
  memory_unread:(unit -> (Keeper_librarian_unread.t list, string) result) ->
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
    [lines] is read only when a snapshot is saved. [memory_unread] is read
    after selecting the point, pairing with writers that archive holes before
    advancing progress. Its result and the raw snapshot's unread observation
    survive a failed snapshot restore and all later request range choices.
    It writes {!choose_continuity}'s notes to [keeper_name]'s log. *)

(** What {!choose_continuity} passed over on the way to its choice, in the
    order it met it. *)
type continuity_note =
  | Snapshot_unusable of { why : string }
      (** A saved snapshot could not be used at all: unreadable, its boundary
          log unreadable, or its covered bytes changed. A warning. *)
  | Progress_unreadable of { why : string; detail : string }
      (** No snapshot fits, and the Librarian's progress file could not be
          read. A warning. *)
  | Unread_memory_unreadable of { detail : string }
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
  memory_unread:(unit -> (Keeper_librarian_unread.t list, string) result) ->
  continuity * continuity_note list
(** {!continuity_for_request}'s choice, with what it passed over returned
    instead of logged. A fitting snapshot and readable Memory evidence produce
    no notes. *)

val log_continuity_note : keeper_name:string -> continuity_note -> unit

val read_keeper_continuity :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  messages:Agent_core.Types.message list ->
  continuity * continuity_note list
(** {!choose_continuity} over [keeper_name]'s own snapshot, turn-boundary
    log, Librarian progress and passively read cumulative Memory unread ledger.
    The turn driver logs the notes; the
    next-request forecast, which only looks, does not. *)

(** The Librarian point a request with a continuity stands on. *)
type librarian_point =
  | At_snapshot of Librarian_continuity_snapshot.t
  | At_read_position of { end_atom : int }

(** Where a request's carried range opens (RFC keeper-context-window-in-tokens
    §13.4, §13.6; RFC librarian-lifecycle §4.10). *)
type range_start =
  | From_snapshot of Librarian_continuity_snapshot.t
      (** A snapshot fits: its working state rides in place of the atoms
          before its end. *)
  | From_read_position of { end_atom : int }
      (** No snapshot fits and the Librarian's read position does: the atoms
          before [end_atom] are not sent, and nothing stands in for them. *)
  | Past_librarian_point of
      { point : librarian_point
      ; accepted : Keeper_carried_front.seed
      }
      (** A Librarian point, and a start the provider accepted on this
          history, at most this turn's boundary: the range opens at
          [accepted]. It lies past the point, or, while the window stays
          ({!held_window}), anywhere. A snapshot's working state still rides
          ahead of it ({!carried_working_state}). The atoms from the point up
          to a later [accepted] are not sent; the part of them the Librarian
          has not read either is {!Keeper_carried_front.librarian_gap}. The
          atoms from an earlier [accepted] up to the point are in memory and
          in the request both. *)
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
  ; moved_at_max_context : Keeper_carried_front.seed option
        (** The front [past_max_context] moved the window to, which the caller
            holds for the rest of the turn; [None] when it moved nothing. *)
  }

(** The size signal (RFC
    a-sent-request-prefix-changes-only-when-the-window-moves §4, D1): at a
    turn's first request, the window the pair's ledger last carried passes
    the binding's max-context once the next turn grows as much as the largest
    turn grew since the ledger started
    ({!Keeper_model_input_ledger.next_turn_peak}). *)
type past_max_context =
  { window_first_atom : int
        (** Where the ledger's last request opened its range. *)
  ; moved_to : Keeper_carried_front.seed
        (** Where the window moves: the end of what the Librarian read when
            that lies past [window_first_atom]
            ({!Keeper_carried_front.Librarian_point_at_max_context}), so the
            atoms the move drops are in memory; else the turn boundary
            ({!Keeper_carried_front.Turn_start_at_max_context}). *)
  ; next_turn_peak : int
  ; max_context : int
  }

val past_max_context :
  max_context:int option ->
  continuity:continuity option ->
  history_digest_at:(int -> string option) ->
  turn_boundary:Keeper_carried_front.turn_start ->
  Keeper_model_input_ledger.t option ->
  past_max_context option
(** [Some] when the ledger's next-turn peak passes [max_context], the ledger
    still holds its positions in this history, and a known [turn_boundary]
    lies past the window's first atom at an atom this history has. [None]
    for no ledger, an unknown count, no [max_context], an unknown boundary,
    or a boundary at or before the window: the signal moves a window early,
    and never moves it back or by a guess. [continuity] names the Librarian
    point the move may go to. Pure. *)

(** What a window that stays keeps where it last sent it (RFC
    a-sent-request-prefix-changes-only-when-the-window-moves §3.1, §3.3). *)
type held_window =
  { window_opened_at : int
        (** Where the ledger's last request opened its range. *)
  ; markers_before : int
        (** The boundary that request demoted below. *)
  ; working_state : string option
        (** The working state that request carried; [None] when it carried
            none. *)
  }

val held_window :
  opens_turn:bool ->
  max_context:int option ->
  history_digest_at:(int -> string option) ->
  Keeper_model_input_ledger.t option ->
  held_window option
(** [Some] when the ledger still holds its positions in this history and,
    at a turn's first request ([opens_turn]), the size signal watches the
    window: [max_context] is declared and the ledger knows how much one turn
    grows ({!Keeper_model_input_ledger.next_turn_peak}). Without the signal,
    a window that keeps its results whole grows until the provider refuses
    it, so that request demotes the turns that ended. Later in the turn the
    window holds where its first request opened it, which the ledger's last
    request records. Pure. *)

val choose_range_start :
  past_max_context:past_max_context option ->
  held_window:held_window option ->
  continuity:continuity option ->
  front:Keeper_carried_front.seed option ->
  accepted:Keeper_carried_front.seed option ->
  history_digest_at:(int -> string option) ->
  turn_boundary:Keeper_carried_front.turn_start ->
  this_turn_start:int option ->
  start_choice
(** The one rule for where a request starts: a snapshot that fits, else the
    Librarian's read position, else [front] when [history_digest_at] opens
    its index with the same message, else [turn_boundary]. A Librarian point
    yields to [accepted] when this history opens its index with the same
    message and it lies after the point ({!Past_librarian_point}): the start
    the provider last accepted, read from the newest response-observed turn
    record, or a front this turn held after a size refusal or the size
    signal (RFC librarian-lifecycle §4.10, rules 1, 2 and 5). It yields to
    an [accepted] at or behind the point too when [held_window] opened
    there: a window that stays holds where it opened, and the point moves it
    only when it moves (RFC
    a-sent-request-prefix-changes-only-when-the-window-moves §3.3). With a known
    [turn_boundary], an [accepted] past it is moved back to it (rule 7). A
    front rule 8 moved to where this turn began
    ({!Keeper_carried_front.This_turn_start_after_seed_refusal},
    {!Keeper_carried_front.This_turn_start_after_librarian_refusal}) is
    bounded instead by the later of [turn_boundary] and where this turn
    began ([this_turn_start], {!turn_starts}), and by [turn_boundary] when
    that start is not known.
    [accepted] is not read
    without a Librarian point, and [front] is not read with one.
    [past_max_context] moves only a window that stays: when the start these
    rules choose opens at its [window_first_atom], the rules run again with
    its [moved_to] as both [front] and [accepted], and the choice names it
    in [moved_at_max_context]. Without a Librarian point the range then
    opens there ({!From_seed}); with one, at the point or past it, so a
    snapshot's working state still rides. A start that opens anywhere else
    has moved the window already: to a Librarian point past it, or to a
    front a refusal held.
    [continuity] is [None] for a request with no trace or one composed from
    a recovery view, and is then read as {!without_snapshot}. Pure: the
    caller reads the files. The turn's composition and
    {!Keeper_next_request_forecast} both call it, so the forecast shows the
    start the request will have. *)

val range_start_origin : range_start -> Keeper_carried_front.origin

val carried_working_state : held_window:held_window option -> range_start -> string option
(** The working state a range opened at [start] carries ahead of its atoms.
    A window that stays, opened where [held_window] says, carries the one it
    carried when it opened, or none when it opened with none: the front of
    the request changes only when the window moves (RFC
    a-sent-request-prefix-changes-only-when-the-window-moves §3.3). Any
    other start carries the working state of the snapshot it reads
    ({!working_state_text}), and none without one. *)

val project_range_start :
  unread:Keeper_librarian_request_unread.t ->
  working_state:string option ->
  measure_message_bytes:(Agent_core.Types.message -> int) ->
  atom_count:int ->
  range_start ->
  Agent_core.Types.message list ->
  Runtime_model_input_tail_window.projection * int
(** The range [start] opens over [messages] of [atom_count] atoms and its
    bytes as [measure_message_bytes] counts them, with [working_state]
    ({!carried_working_state}) ahead of the atoms it stands in for. *)

type request_input =
  | Keeper_history of { trace_id : string; continuity : continuity }
  | Completion_review
(** A prepared Keeper input always contains its checked continuity. A
    program-owned review carries original evidence, without a fabricated trace
    or snapshot and without history eviction or result-marker retries. *)

type try_provider_ctx =
  { runtime_id : string
  ; input_runtime : Runtime_instance.t option
        (** Materialized dispatch's selected model/execution snapshot, carried
            unchanged to Runtime_agent preflight. [None] retains runtime-ID
            lookup for callers without a materialized selection. *)
  ; error_runtime_id : string
  ; carried_front_seed : unit -> Keeper_carried_front.seed_read
        (** The durable seed: with no Librarian point, read only when
            neither the pair's ledger nor a refusal in this turn supplies the
            front; with one, the accepted start {!choose_range_start} weighs
            against the point, read unless a refusal in this turn supplies
            it. *)
  ; request_input : request_input
  ; turn_boundary : Keeper_carried_front.turn_start
  ; this_turn_start : int option
        (** Where this turn began, read once per turn from the turn log
            ({!turn_starts}). Rule 8 resends from it, and rule 7 bounds the
            front rule 8 held by it (RFC librarian-lifecycle §4.10). [None]
            when the log names no start for this history. *)
  ; carried_front_after_refusal : unit -> Keeper_carried_front.seed option
        (** The latest refusal's front, shared by every Agent Core candidate
            of this turn. A valid later front takes precedence over the
            candidate's ledger, including when that ledger predates it. *)
  ; hold_carried_front : Keeper_carried_front.seed -> unit
        (** Keeps a front moved by either halving or block eviction after a
            refusal. It names an atom of the shared checkpoint history. *)
  ; restore_carried_front : Keeper_carried_front.seed option -> unit
        (** Puts back the front held before a boundary resend that the
            provider refused for a reason other than size. *)
  ; base_path : string
  ; outbox_viewer : Keeper_client_tool_outbox.viewer
      (** Which retained receipts this attempt's run may carry. *)
  ; media_store : Agent_core.History.media_store
      (** The media of this Keeper's history; the attempt's agent and its
          request projection read and write it. *)
  ; keeper_name : string
  ; name : string
  ; goal : string
  ; goal_blocks : Agent_core.Types.content_block list option
  ; goal_metadata : Agent_core.Types.metadata
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; initial_messages : Agent_core.Types.message list
  ; argument_demotion_seed : Agent_core.Types.message list option
  ; argument_replay_prefix : Keeper_replay_prefix.projection
  ; prepare_request_media : Keeper_history_projection.preparation
        (** Prepare the selected runtime's request-only media view for
            [Keeper_history], using the lane walk's shared readers.
            [Completion_review] retains its separate admitted-evidence contract
            and does not call this. Runs once on the owning fiber after the
            first canonical range selection and materialization. The returned
            projection reuses frozen results for every dialect/prefix check,
            including argument-protection fallback. It preserves message order,
            roles, origins, metadata and ToolResult identity/outcome/JSON,
            changing only media blocks. Reader failures remain typed errors or
            explicit unavailable readings; canonical history is unchanged. *)
  ; read_retained_media : Keeper_client_tool_outbox.media_reader option
      (** Shared attachment reader for the retained Text carrier. This does not
          change native history projection. Completion review passes [None]. *)
  ; model_input_projection : Keeper_history_projection.t option
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
  ; checkpoint_sink : Agent_core.Agent.checkpoint_sink option
  ; checkpoint_progress : checkpoint_progress Atomic.t
  ; context_injector : Agent_core.Hooks.context_injector option
  ; context : Agent_core.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; cooperative_yield_probe : Runtime_agent.cooperative_yield_probe option
  ; agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; on_request_evidence : (Request_observation.evidence -> unit) option
  ; on_request_execution_ready : (runtime_id:string -> execution:Types_core.verifier_execution_reference -> (unit, string) result) option
  ; native_binding : Keeper_direct_native_continuation.binding option
  ; native_retired_history_cut : Keeper_direct_native_continuation.retired_history_cut option
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
       projected_messages:Agent_core.Types.message list option ->
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
(** Cooperative yields retain their continuation. A repetition stop instead
    ends this invocation with its typed host cause; it must not enter the
    ordinary checkpoint/requeue path. This does not authorize replay or
    provider rotation after effects. *)

val complete_saved_tool_terminal :
  tool_results_saved_in_attempt:bool ->
  observed_provider_turn_ordinal:int option ->
  checkpoint:Agent_core.Checkpoint.t option ->
  (Runtime_agent.run_result, Agent_core.Error.t) result ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Keeper-owned normalization of a typed empty [EndTurn] failure after this
    attempt saved tool results. A checkpoint and an actual provider ordinal
    observed during this SDK invocation are required; the latter is never
    inferred from checkpoint counts or another attempt. An invocation without
    that witness (including a restored tool turn without a fresh AfterTurn)
    retains its original error. All other outcomes
    retain their original classification. The synthetic terminal has no
    provider response identity, usage, telemetry or cooperative-yield witness. *)

val observe_checkpoint_stage :
  checkpoint_progress Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit
(** Marks that a stage was reached. Called before the stage is saved. *)

val observe_checkpoint_saved :
  checkpoint_progress Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit
(** Marks tool/context progress or a distinct assistant-save witness. Only the
    owner of the checkpoint sink may call it, and only for a write it made:
    a sink answers [Ok ()] for a write it skipped as well
    ([Keeper_checkpoint_store.Stale_noop], which leaves the canonical
    checkpoint untouched), and a resumed operation would not read the
    checkpoint that write claimed. Assistant saves do not establish saved
    tool results; an attempt observes their growth only inside its own
    assistant-stage callback, paired with its actual provider turn. *)

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
(** [true] only when a tool/context checkpoint was actually saved, including
    when a later assistant save preserved that fact. *)

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

val default_context_overflow_shrink_capacity : capacity:int -> int
(** The shared provider-oracle target for one ordinary shrink step. The
    runtime-specific caller may clamp this target further to structural
    message boundaries. *)

val context_overflow_shrink_sequence :
  ?shrink_capacity:
    (capacity:int -> default_capacity:int -> int) ->
  ?final_shrink_capacity:(capacity:int -> int option) ->
  ?on_memory_capacity_refusal:Keeper_memory_delivery_reprojection.t ->
  ?on_memory_retry:(unit -> unit) ->
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
    carried front ({!run_try_provider_with_truncation_recovery}).
    After a typed window or request-body refusal and same-run effect
    authorization, memory
    reprojection is offered first. [Reprojected] retries at the same history
    capacity after [on_memory_retry] resets caller recovery state. [Unchanged]
    uses history shrinking; a callback error preserves the original refusal
    without retry. The default callback returns [Unchanged].
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

val boundary_resend_on : Agent_core.Error.t -> bool
(** The refusals {!turn_boundary_resend_sequence} answers: a typed size
    refusal ([ContextOverflow], [Request_body_refused_by_provider]) and a
    refusal whose reason agent core does not model
    ([Unknown_invalid_request]), which is how live size refusals arrive.
    [is_size_refusal] names only the typed two (#38286). A refusal that was
    not about size is refused again from the boundary, the front held before
    it is given back, and no accepted start at the boundary is recorded; one
    that was leaves atoms the Librarian still reads. *)

val turn_boundary_resend_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  refused_range:(unit -> (Keeper_carried_front.origin * int) option) ->
  turn_start_front:(unit -> Keeper_carried_front.seed option) ->
  held_front:(unit -> Keeper_carried_front.seed option) ->
  restore_front:(Keeper_carried_front.seed option -> unit) ->
  hold_front:(Keeper_carried_front.seed -> unit) ->
  on_turn_start:(Agent_core.Error.t -> Keeper_carried_front.seed -> unit) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The retry policy of a turn with a continuity choice, over an injected
    [attempt] (RFC keeper-context-window-in-tokens §13.4; RFC
    librarian-lifecycle §4.10, rule 1). When [attempt] fails with a refusal
    {!boundary_resend_on} names, [refused_range] reports that the refused range opened on a seed
    ({!Keeper_carried_front.Carried}), a Librarian point, or an accepted
    start past one, at its first atom, [turn_start_front] names the turn
    boundary strictly after that atom
    ({!Keeper_carried_front.Turn_start_after_seed_refusal} or
    {!Keeper_carried_front.Turn_start_after_librarian_refusal}), and
    [same_run_retry_authorized] holds, the boundary is given to [hold_front]
    as the turn's front, [on_turn_start] is told, and [attempt] runs once
    more; its result is returned as it is. When that second attempt is
    refused for a reason {!is_size_refusal} does not name, [restore_front]
    gets back what [held_front] reported before the hold, so a refusal that
    was not about size leaves the turn's front where it was. Every other failure is returned
    at once, so a candidate that already opens at the held boundary is not
    asked twice. The range is never halved: an accepted boundary request is
    what the ledger records, so the next turn's seed is that boundary. *)

val this_turn_start_resend_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  refused_first_atom:(unit -> int option) ->
  this_turn_front:(unit -> Keeper_carried_front.seed option) ->
  held_front:(unit -> Keeper_carried_front.seed option) ->
  restore_front:(Keeper_carried_front.seed option -> unit) ->
  hold_front:(Keeper_carried_front.seed -> unit) ->
  on_this_turn_start:(Agent_core.Error.t -> Keeper_carried_front.seed -> unit) ->
  first:(unit -> ('ok, Agent_core.Error.t) result) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** The last rung of a size refusal (RFC librarian-lifecycle §4.10, rule 8),
    over an injected [first] (the rungs before it) and [attempt]. When
    [first] fails with a refusal {!is_size_refusal} names,
    [same_run_retry_authorized] holds, and [this_turn_front] names where this
    turn began strictly after [refused_first_atom]
    ({!Keeper_carried_front.This_turn_start_after_seed_refusal} or
    {!Keeper_carried_front.This_turn_start_after_librarian_refusal}), that
    front goes to [hold_front], [on_this_turn_start] is told, and [attempt]
    runs once more;
    its result is returned as it is. When that attempt is refused for a reason
    {!is_size_refusal} does not name, [restore_front] gets back what
    [held_front] reported before the hold. Every other failure of [first] is
    returned at once. *)

type current_turn_results =
  | Current_turn_verbatim
      (** No size refusal yet: this turn's results keep their ordinary form. Completed
          turns may carry result markers and verified argument references
          under {!finished_turn_results}. *)
  | Current_turn_demoted of { refused_atom_count : int }
      (** A request carrying [refused_atom_count] atoms was refused for size:
          every tool result below [refused_atom_count], and every completed
          argument the attempt bound, goes as its externalized marker
          (#28845). Atoms appended after the refused ones, the results a
          resent attempt produces, go as they are. *)

(** What a composition under {!Current_turn_verbatim} does with the tool
    results of turns that already ended, the atoms before the turn boundary.
    Marker projection also archives the supplied, independently bound completed
    arguments below the same boundary. Unbound or signed-prefix-protected arguments stay verbatim.
    The resend that answers a size refusal ignores it:
    {!Current_turn_demoted} covers every result of the refused request. *)
type finished_turn_results =
  | Finished_turns_verbatim
      (** Every result goes as the range first sent it (RFC-0363 §3.4.1). *)
  | Finished_turns_as_markers
      (** A result of turns that ended, in an atom before the boundary and
          never the newest atom, goes as its externalized marker when its
          body is at least {!aged_result_min_bytes} bytes. The boundary is
          the one the window last sent while the window stays
          ({!held_window}), and the turn boundary once it moves (RFC
          a-sent-request-prefix-changes-only-when-the-window-moves §3.1).
          The same result is the same marker on every later request, so it
          changes once, on the first request whose window moved after its
          turn ended (RFC-tool-results-age-out-of-context). With an unknown
          turn boundary a window that moves demotes nothing. *)

val finished_turn_results_for : reader_available:bool -> finished_turn_results
(** {!Finished_turns_as_markers} for a Keeper that can read markers back
    ([reader_available]); {!Finished_turns_verbatim} for a Keeper without the
    reader. *)

val aged_result_min_bytes : int
(** The least text, in bytes, of a result of an ended turn that goes as its
    marker; a smaller result stays readable in the prompt. A retained
    official-client receipt is a result of an ended vendor turn and uses the
    same floor ([Keeper_client_tool_outbox.host_response]). *)

val current_turn_demotion_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  demotable:(unit -> int option) ->
  demote:(Agent_core.Error.t -> refused_atom_count:int -> unit) ->
  first:(unit -> ('ok, Agent_core.Error.t) result) ->
  resend:(unit -> ('ok, Agent_core.Error.t) result) ->
  unit ->
  ('ok, Agent_core.Error.t) result
(** An answer to a size refusal, on every continuity (RFC
    keeper-context-window-in-tokens §10.4, §13.9), before
    {!this_turn_start_resend_sequence}. When [first] fails with a
    typed size refusal {!is_size_refusal} names,
    [same_run_retry_authorized] holds, and [demotable] names the refused
    request's atom count because demoting the tool results and bound
    arguments in it would carry fewer bytes, [demote] is told and [resend]
    runs once; its
    result is returned as it is. The range is not narrowed. With nothing to
    demote, and on every other failure, the failure is returned at once. *)

val memory_capacity_retry_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  on_memory_capacity_refusal:Keeper_memory_delivery_reprojection.t ->
  on_projection_failure:(unit -> unit) ->
  attempt:(unit -> ('ok, Agent_core.Error.t) result) -> unit ->
  ('ok, Agent_core.Error.t) result
(** Agent Core memory feedback before any carried-range mutation. Only typed
    window/body capacity refusals and current checkpoint/effect authority permit
    retry. Receipt failure calls [on_projection_failure] so enclosing history
    recovery cannot bypass it. Unchanged memory returns the original refusal. *)

val connection_recovery_sequence :
  same_run_retry_authorized:(unit -> bool) ->
  on_reconnect:(Llm_provider.Http_client.network_error_kind -> unit) ->
  reconnect:(unit -> (('ok, Agent_core.Error.t) result * 'checkpoint * 'sample)) ->
  attempt:(unit -> (('ok, Agent_core.Error.t) result * 'checkpoint * 'sample)) ->
  unit -> (('ok, Agent_core.Error.t) result * 'checkpoint * 'sample)
(** A typed peer reset/EOF before checkpoint or effect progress may be answered
    by rebuilding the same HTTP attempt with fresh connections. The reconnect
    result is returned directly, including its checkpoint and failure; it does
    not enter another reconnect loop. Other failures remain unchanged.

    The reset/EOF must come from a connection that had opened
    ([Http_client.NetworkError]). A connection that never opened
    ([Http_client.Connect_failed]) was not a reused one, so fresh connections
    are not its remedy, whatever its kind: a reset or EOF during the TLS
    handshake of a new connection is not rebuilt. The walk moves to the next
    candidate (RFC #52028 §3.5). *)

val run_try_provider_with_truncation_recovery :
  ?on_memory_capacity_refusal:Keeper_memory_delivery_reprojection.t ->
  ?continuation_checkpoint:Agent_core.Checkpoint.t ->
  try_provider_ctx ->
  Runtime_candidate.t ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
  * Agent_core.Checkpoint.t option
  * (string * Obj.t) option
(** One run: every provider attempt to this candidate. The history recovery
    sends a completion review once with its original evidence; the
    continuation below may follow it. A Keeper input retains memory
    reprojection, verified boundary resend, current-tool demotion and the
    resend from where this turn began, under the existing checkpoint/effect
    retry authority; on a typed size refusal
    the retained-result carrier is offered before [on_memory_capacity_refusal]
    ({!Keeper_client_tool_outbox.run_carrier_reprojection}).

    A materialized Agent Core HTTP lane whose connection closes before any
    stream event or checkpoint/effect progress reconnects with an uncached
    transport. Official clients retain their own recovery. HTTP itself never
    replays a POST.

    Run the carried-range eviction first. When the accepted
    boundary instead reports a typed [MaxTokens] truncation, remove only that
    incomplete Assistant message from the post-run checkpoint and continue the
    same candidate once with thinking disabled. No new User message is added,
    so already-recorded tool results remain the continuation authority.

    The continuation is the run's next attempt, not a fresh one. It carries
    the tool results a size refusal demoted as markers, and the
    retained-result carrier in the form a size refusal left it. The first
    attempt loads the outbox, and the attempt that completes acknowledges that
    snapshot (RFC retained-results-carrier-shrinks-to-an-address §1, §5.1,
    §6.1). *)

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
  ; demote_before : int
        (** The boundary the demotion applied: 0 under {!Current_turn_verbatim}
            with {!Finished_turns_verbatim} or with no store; under
            {!Finished_turns_as_markers} the held boundary while the window
            stays, else the last ended turn's end; the refused request's atom
            count under {!Current_turn_demoted}. *)
  ; working_state : string option
        (** The working state the range carried ahead of its atoms
            ({!carried_working_state}). *)
  ; moved_at_max_context : Keeper_carried_front.seed option
        (** The front the size signal moved this range to
            ({!start_choice}), which the rest of the turn holds. *)
  }
(** One request as {!For_testing.compose_carried_model_input} composes it
    (RFC keeper-context-window-in-tokens §10.4): under {!Current_turn_demoted}
    RFC-0363 demotion over every atom up to the refused request's end, then
    the carried range from where {!choose_range_start} opens it (§13.4,
    §13.6). Under {!Current_turn_verbatim} nothing the range already sent is
    rewritten but the results and verified arguments {!Finished_turns_as_markers} asks for. Nothing
    here measures the request against a limit. *)

type request_view =
  { composed : composed
  ; completed_arguments : Keeper_model_input_demotion.completed_arguments option
        (** Frozen eligibility, narrowed when exact signed reasoning replay
            requires an earlier argument prefix to remain verbatim. *)
  ; argument_prefix_protected : bool
  ; carried : Agent_core.Types.message list
        (** The composed messages with their demotions materialized: what the
            ledger and the turn record count, in atoms of the checkpoint
            history. *)
  ; projected_carried : Agent_core.Types.message list
        (** [carried] after the request-only media projection. Message
            occurrence coordinates are unchanged. Both wire resolution and
            dialect/prefix inspection consume this same view. *)
  ; carried_wire : Agent_core.Llm_provider.Types.message list
        (** [projected_carried] with its remaining media read back from the
            store, and nothing else of the history. *)
  ; transmitted :
      ( Agent_core.Types.message list
        , Agent_core.Llm_provider.Reasoning_history_projection.error )
        result
        (** The dialect's reasoning projection over [projected_carried], still
            in history form, or why it declined; [projected_carried] itself is
            then handed over, and the backend, running the same projection,
            refuses the request with its typed error. *)
  }
(** One request as {!For_testing.request_view} views it: composed in the
    durable vocabulary first, projected for the wire afterwards. The order
    keeps atom positions a property of the history rather than of the
    dialect, so a front measured on one runtime names the same atom on every
    runtime whatever reasoning each replays or deletes. *)

module For_testing : sig
  val this_turn_front_source : continuity -> Keeper_carried_front.source
  (** The source of a front rule 8 moves to where this turn began:
      {!Keeper_carried_front.This_turn_start_after_librarian_refusal} with a
      Librarian point, {!Keeper_carried_front.This_turn_start_after_seed_refusal}
      without one. *)

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

  val tool_result_save_count : checkpoint_progress Atomic.t -> int

  val memoize_message_measurement :
    (Agent_core.Types.message -> int) -> Agent_core.Types.message -> int

  val memoize_wire_message :
    Agent_core.History.media_store ->
    Agent_core.Types.message ->
    (Agent_core.Llm_provider.Types.message, Agent_core.History.media_error) result
  (** The production attempt's wire conversion cache, keyed by the projected
      message value. Reusing a canonical message in a different request media
      view must not reuse its earlier wire body. *)

  val message_measurement_hash : Agent_core.Types.message -> int

  val aged_result_min_bytes : int
  (** The least body, in bytes, of a result {!Finished_turns_as_markers}
      sends as a marker. *)

  (** [same_turn_result_as_pointer], asked with the name in a history
      [ToolUse] block, says whether that tool's repeated results leave as a
      pointer to the turn's first one ({!Keeper_same_turn_result_stub},
      RFC-0510). Omitted, no tool does. The pointer is placed before the
      demotion plan, on the range the checkpoint history chose.
      [past_max_context] goes to {!choose_range_start}; omitted, no window
      moves for size. The turn driver passes it at a turn's first request.
      [held_window] keeps the markers, arguments and working state of a
      window that stays where they were last sent; omitted, the markers and
      arguments follow the turn boundary and the working state is the
      snapshot's. *)

  val compose_carried_model_input :
    ?continuity:continuity ->
    ?completed_arguments:Keeper_model_input_demotion.completed_arguments ->
    ?past_max_context:past_max_context ->
    ?held_window:held_window ->
    ?finished_turn_results:finished_turn_results ->
    ?this_turn_start:int ->
    ?same_turn_result_as_pointer:(string -> bool) ->
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    measure_wire_bytes:(Agent_core.Types.message -> int option) ->
    front:Keeper_carried_front.seed option ->
    accepted:Keeper_carried_front.seed option ->
    history_digest_at:(int -> string option) ->
    current_turn_results:current_turn_results ->
    base_path:string ->
    turn_boundary:Keeper_carried_front.turn_start ->
    Agent_core.Types.message list ->
    composed

  val request_view :
    ?continuity:continuity ->
    ?completed_arguments:Keeper_model_input_demotion.completed_arguments ->
    ?past_max_context:past_max_context ->
    ?held_window:held_window ->
    ?finished_turn_results:finished_turn_results ->
    ?this_turn_start:int ->
    ?same_turn_result_as_pointer:(string -> bool) ->
    ?tools:Yojson.Safe.t list ->
    provider_config:Agent_core.Llm_provider.Provider_config.t ->
    measure_message_bytes:(Agent_core.Types.message -> int) ->
    measure_wire_bytes:(Agent_core.Types.message -> int option) ->
    front:Keeper_carried_front.seed option ->
    accepted:Keeper_carried_front.seed option ->
    history_digest_at:(int -> string option) ->
    current_turn_results:current_turn_results ->
    base_path:string ->
    turn_boundary:Keeper_carried_front.turn_start ->
    materialize:
      (pending:Keeper_model_input_demotion.pending list ->
       Agent_core.Types.message list ->
       Agent_core.Types.message list) ->
    prepare_request_media:Keeper_history_projection.preparation ->
    to_wire:
      (Agent_core.Types.message ->
       (Agent_core.Llm_provider.Types.message, Agent_core.History.media_error) result) ->
    Agent_core.Types.message list ->
    (request_view, Agent_core.Error.t) result
  (** Media preparation and projection failures retain their original typed
      error. Only Stored-to-wire failures become [Agent_core.Error.Media].
      Prepare once from the first selected materialization on the owning fiber,
      outside CPU projection work. Every argument-prefix comparison and fallback
      reuses its returned projection; a custom materializer cannot authorize
      another preparation. *)

  val current_turn_demotion : refused:composed -> demoted:composed -> int option
  (** Whether [demoted], the refused range composed under
      {!Current_turn_demoted}, carries fewer bytes than [refused], both
      measured with the plan's placeholders: the refused request's atom count
      when it does, [None] when there is nothing to demote in it. A body the
      lane's encoder does not send is never demoted, so fewer bytes here are
      fewer on that lane's wire. *)

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

  val offload_model_input_cpu : (unit -> 'a) -> 'a

end
