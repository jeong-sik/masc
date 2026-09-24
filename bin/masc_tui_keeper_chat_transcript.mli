(** What one keeper turn looks like while it is still running.

    {!Masc_tui_keeper_chat_live} says what arrived; this accumulates it into
    the shape the chat pane draws: the assistant text so far, the reasoning so
    far, and one row per tool call with the argument a reader identifies it by.

    It holds no authority over the turn. The recorded reply still comes from
    the strict whole-body decode when the stream ends, and this is discarded
    at that point. *)

(** How far along the turn is, as far as the stream has said. *)
type phase =
  | Waiting  (** The request went out; the run has not started. *)
  | Working  (** The run started and the stream is open. *)
  | Stream_ended  (** The run reported it finished. *)
  | Stream_failed of string  (** The run reported an error. *)

(** What came of an operator's request to interrupt this turn.

    [Signal_sent] is not "the turn stopped". The server reports whether it
    signalled the running fiber, and a turn parked in an uncancellable section
    keeps going after a signal lands — reading it as the outcome is what hid a
    63-minute hang (masc #29229). The stream ending is the proof.
    [signalled_at_ns] is a monotonic timestamp ([Mtime_clock.elapsed_ns]),
    so a reader can tell a fresh signal from one the turn has long since
    ignored without a wall-clock step re-opening the question. *)
type interrupt =
  | Not_requested
  | Signal_sent of { turn_id : int option; signalled_at_ns : int64 }
  | Admission_paused
  | Signal_declined of string
      (** The server accepted the request and did not signal — no turn in
          flight, or the cancel itself failed. Carries its reason. *)
  | Signal_error of string  (** The request never got an answer. *)

(** What the source says happened to a tool call. Live calls distinguish a
    call still accepting arguments from one whose invocation ended but whose
    result has not landed. Durable traces additionally distinguish an explicit
    failure, an explicitly open call, and an absent outcome. *)
type tool_outcome =
  | Started
  | Awaiting_result
  | Returned
  | Failed
  | Never_returned
  | Outcome_unrecorded

val outcome_label : tool_outcome -> string
(** The word the block rollup counts an outcome by ([3 returned]). *)

val marker_of_outcome : tool_outcome -> string
(** The one-cell mark a call row leads with for its outcome. *)

val all_outcomes : tool_outcome list
(** Every outcome, in rollup order. *)

(** One tool call as shared by the live turn and durable history decoders.
    This remains typed until {!project_tool_block}; consumers never recover
    identity or outcome by parsing a rendered row. *)
type tool_activity = private
  { call_id : string option
      (** Stable producer identity when the source carried one. [None] is kept
          for a trace step that did not carry an id; no positional id is
          invented. *)
  ; execution_id : string option
      (** Canonical physical-execution identity after result persistence.
          Separate from provider [call_id], which may be blank or repeated
          outside its source scope. *)
  ; tool_name : string
  ; args : string  (** Argument text accumulated or persisted by the source. *)
  ; subject : string option
      (** The one argument a reader names the call by, or [None] while the
          arguments are still arriving or carry no known key. Same naming as
          the connector trail and the dashboard. *)
  ; outcome : tool_outcome
  ; duration : string option
      (** The source's duration label. Live events do not currently carry one,
          so they retain [None]. *)
  }

(** What exact Skill evidence says, kept separate from ordinary tool outcome.
    A successful [keeper_skill] call proves that Skill content was served; it
    does not prove the provider received it or that a later action used it. *)
type skill_state =
  | Skill_calling
  | Skill_served_pending
  | Skill_served_only
  | Skill_delivered
  | Skill_used
  | Skill_failed
  | Skill_evidence_missing
  | Skill_evidence_unavailable

(** How the skill was invoked, off the server's [invocation.kind] for a
    durable activation and off the tool's name for a live call: an
    instruction skill is read as text, a composition is run as the tool
    named after it. The rows say "read" or "run" accordingly. *)
type skill_invocation =
  | Instruction_read
  | Composition_run of { tool_name : string }

val skill_state_label : ?invocation:skill_invocation -> skill_state -> string
(** The phrase a full skill row leads with, one per state. A skill's life is
    read (or, for a composition, run), delivered, used, and the phrase says
    how far it got; the last three states are not steps of that life and say
    so. *)

val all_skill_states : skill_state list
(** Every state, in the order of the skill's life. *)

val legend : (string * string) list
(** Each mark and phrase a tool or skill row can carry, with what it means,
    for the help sheet. Built from {!outcome_label} and
    {!skill_state_label}, so it prints the words the rows print. *)

type skill_activity = private
  { skill_name : string
  ; invocation : skill_invocation option
      (** [None] only on the rows the pane makes for evidence it could not
          read ([Skill_evidence_missing], [Skill_evidence_unavailable]);
          every decoded activation and every live call carries one. *)
  ; skill_tool_use_id : string option
  ; turn_ref : string option
  ; content_revision : string option
  ; runtime_id : string option
  ; state : skill_state
  ; actions : string list
  ; detail : string option
  }

val make_skill_activity :
  ?invocation:skill_invocation ->
  ?skill_tool_use_id:string ->
  ?turn_ref:string ->
  ?content_revision:string ->
  ?runtime_id:string ->
  ?detail:string ->
  skill_name:string ->
  state:skill_state ->
  actions:string list ->
  unit ->
  skill_activity
(** Construct one typed Skill evidence row. Optional identity fields remain
    absent when the producer did not carry them; the renderer never invents a
    join key. *)

val skill_activity_of_tool : tool_activity -> skill_activity option
(** Project a live Skill-as-tool call. [Some] is returned only for the stable
    Skill tool family. A returned call is [Skill_served_pending] until durable
    delivery evidence replaces the live row. *)

val skill_rows : full:bool -> skill_activity list -> string list
(** Markdown rows for one block of Skill invocations. Compact: one row per
    skill named in the block, in first-trigger order, with how many times
    it was triggered ([**msx-observe** ×7]) and, only when a trigger failed
    or its evidence could not be read, that state's words. [full]: each
    invocation's state and name, its observed actions, its proof
    coordinates and its detail. *)

val skill_block_state : skill_activity list -> skill_state
(** The state a block of invocations draws in: the worst of them. *)

(** A contiguous block of tool calls. [omitted_steps] is a durable transcript
    fact, not the number of rows a compact projection hides. *)
type tool_block = private
  { activities : tool_activity list
  ; omitted_steps : int
  }

type tool_projection_mode =
  | Compact
  | Full

(** Rows derived from one typed block. Both modes retain [activities] in the
    same order. [hidden_activity_rows] is exact: zero for [Full], and the
    number of per-call detail rows folded into a compact summary. *)
type tool_projection = private
  { activities : tool_activity list
  ; header : string option
        (** The block's rollup, on a line of its own: what ran, how it ended,
            how many rows are behind a fold. [None] for a block of one call --
            a summary of one call is that call, and drawing both says the same
            thing twice.

            Split from [details] rather than prepended to it because the two
            are drawn differently: the header is where a fold is toggled and
            carries the block's mark, while a detail row is one call. A
            consumer that had to tell them apart by reading the text would be
            recovering a distinction this type already knows. *)
  ; details : string list
        (** One row per call in arrival order, and the calls that need naming
            even while folded. Never indented here: how far a detail sits from
            its header is the layout's decision, and baking it into the string
            would fix it for every pane width. *)
  ; hidden_activity_rows : int
  ; omitted_steps : int
  ; summary_outcome : tool_outcome option
        (** The outcome the [header] stands for while it is holding calls
            behind a fold, and [None] when nothing is folded -- including
            [Full], which draws a header over details that are all visible.

            A chat body is sanitized before it is drawn -- a row cannot carry
            an escape into the terminal -- so a marker inside the text cannot
            be coloured, and the row's own style is the only channel a reading
            of state has. Folding is what makes that channel matter: [Full]
            gives every call a row and a glyph of its own, while a fold puts
            six calls behind a summary. The failed and still-open calls now sit
            on a row of their own under their own mark, so the trouble is a
            line rather than a clause mid-sentence; that row still carries the
            block's single colour, which is what this field is about.

            Same precedence as the summary glyph, from the same function, so
            the mark and the colour cannot disagree about one block. *)
  }

val make_tool_activity :
  ?execution_id:string ->
  call_id:string option ->
  tool_name:string ->
  args:string ->
  outcome:tool_outcome ->
  duration:string option ->
  unit ->
  tool_activity
(** Build an activity and derive its [subject] through the shared tool-subject
    authority. History and live projection must not derive it independently. *)

val descriptor_of_tool_name : string -> Masc.Keeper_tool_descriptor.t option
(** The registry's descriptor for a tool name as a trace carries it: the
    public name first, then an internal alias. [None] for a name no
    registered tool answers to. *)

val tool_block : ?omitted_steps:int -> tool_activity list -> tool_block

val project_tool_block : tool_projection_mode -> tool_block -> tool_projection
(** The only tool-row formatter. [Full] preserves the existing one-row-per-call
    output. [Compact] folds two or more calls into an inventory row -- what
    ran, and what returned -- and, when any call failed or is still open, one
    further row naming those under their own mark. A block whose calls all
    returned keeps a single row. Both modes state the exact number of hidden
    detail rows, and neither fabricates missing identity, duration, outcome, or
    omitted transcript steps. *)

(** Live stream diagnostics, including lines the reader could not read and
    typed server protocol errors. Kept because dropping either makes a failed
    tool look healthy. *)
type unreadable =
  { count : int
  ; last_detail : string
  }

(** A tool call the keeper is holding, waiting to be answered. [because] is
    why it was held; it is drawn under the question in the pane. *)
type awaiting_approval =
  { call_id : string
  ; tool_name : string
  ; question : string
  ; because : string
  }

type t

val create :
  keeper_name:string -> request_id:string -> started_at:float -> t
(** [started_at] is when the request was dispatched, not when the run
    started. The gap between the two is the part a watcher most needs an
    age for: a request that never reaches RUN_STARTED is what hid a
    63-minute hang (masc #29229). *)

val keeper_name : t -> string
val request_id : t -> string
val execution_id : t -> string
(** Shared batch execution owner, or the singleton request identity. *)
val started_at : t -> float
(** The dispatch instant supplied to {!create}. Exposed as typed timeline
    input so a live turn keeps its original civil-hour rail while it grows. *)

val settled_at : t -> float option
(** The instant the turn's outcome landed: the first of Run_finished,
    Run_failed or Reply_details, stamped by the {!apply} that carried it. A
    turn still running is [None]. Together with {!started_at} it bounds the
    span a block drawn from this transcript covered. *)

val apply : now:float -> t -> Masc_tui_keeper_chat_live.delta -> unit
(** [now] stamps a tool call as it opens, so the progress row can say how long
    the call in flight has been open rather than only how long the turn has. *)
(** Fold one delta in. Tool deltas join only by their server-owned stream
    occurrence. Provider ids are optional correlation data; an unknown
    occurrence is reported unreadable rather than attached by position. *)

val note_interrupt : t -> interrupt -> unit

val note_tool_outcome :
  t -> execution_id:string -> outcome:tool_outcome -> duration:string option -> bool
(** Folds in what the durable transcript recorded for one call -- its outcome
    and its [dur] -- matched by execution id; returns whether a call matched.
    The wire does not carry either yet (RFC-0412 stage 4 moves them there), so
    a turn drawn from its log would otherwise show a failed call as returned
    and no durations once the loaded rows are left out of the timeline. A
    durable outcome that says less than the stream saw ([Never_returned],
    unrecorded) changes nothing. *)

val note_skill_activity : t -> skill_activity -> unit
(** Folds in the exact delivery record of one skill read -- the states the
    wire has no event for ([Skill_served_only], [Skill_delivered],
    [Skill_used]), the calls the read led to, and the proof ids -- keyed by
    its [skill_tool_use_id]. A record in a state the stream speaks for
    itself (calling, pending, failed) or an evidence gap changes nothing,
    and neither does one without a tool-use id. A second record for the
    same id replaces the first. {!drawn} lays the record over the skill item
    derived from the same call, and draws it on its own when the trail never
    saw that call. *)

val revision : t -> int
(** Bumped by every mutation ({!apply}, {!note_interrupt},
    {!note_tool_outcome}, {!note_skill_activity}): the memo key for anything
    drawn from this transcript. *)

val phase : t -> phase
val awaiting_continuation : t -> bool
(** A checkpoint segment ended; the original request still awaits its answer. *)
val admission : t -> (Masc_tui_keeper_chat_live.admission * int) option
(** Server acceptance and queue length observed at acceptance, if received.
    This remains historical after the run starts; inspect [phase] alongside it. *)
val interrupt : t -> interrupt
val text : t -> string
val thinking : t -> string

val thinking_lines : t -> string list
(** The reasoning trail the pane draws: every non-blank line, in order.
    Blank lines are dropped because models emit runs of them. Not the
    last line alone -- reasoning is the only part of a live turn the
    durable transcript does not keep, so the pane is the one place it can
    be read. *)
val tool_calls : t -> tool_activity list
(** In the order the stream opened them. Unresolved calls in a terminal or
    superseded attempt are [Never_returned]; recorded results are preserved. *)
val unreadable : t -> unreadable option

(** One stretch of the turn, in arrival order. A tool-call round interleaves
    reasoning, calls and reply text; {!text}, {!thinking_lines} and
    {!tool_rows} answer the totals, this answers the order, which is what a
    reader follows a long turn by. Tool stretches stay typed; text and
    reasoning strings are terminal-safe. *)
type trail_item =
  | Trail_thinking of string list
      (** Reasoning lines of one contiguous stretch. A paragraph break is one
          empty line; the stretch never opens or closes on one. *)
  | Trail_skill of skill_activity list
      (** One contiguous run of Skill-as-tool calls, separated from generic
          tools so the chat can give their delivery/usage semantics a
          distinct visual treatment and count them as one row. *)
  | Trail_tools of tool_block
      (** One contiguous run of typed calls. A call keeps updating its facts
          (arguments, outcome) after later stretches open. *)
  | Trail_text of string  (** One contiguous stretch of reply text. *)
  | Trail_superseded of
      { attempt : int
      ; runtime_id : string option
      ; items : trail_item list
      }
      (** What runtime attempt [attempt] produced before the next attempt
          began, in order. Kept rather than wiped (RFC-0412 §3.3) so a retry
          never takes back what the reader was reading; the pane marks it.
          One block per superseded attempt, siblings in the trail in attempt
          order, never nested: a boundary folds only the stretches since the
          previous boundary. *)

val trail : t -> trail_item list
(** Empty stretches are dropped, so every item draws at least one row. *)

val attempt : t -> int
(** 0-based runtime attempt the growing trail belongs to. *)

val current_runtime_id : t -> string option
(** Current resolved-runtime identity, if observed. *)

val runtime_identity_text :
  keeper_name:string -> configured_runtime:string -> t option -> string
(** Labels the configured runtime separately from the matching turn's observed
    runtime ([turn: <runtime id>]). A stream that named its model before any
    runtime id was announced is labelled [model: <model>]: a model name is not
    a runtime id and is never shown as one. Another keeper's transcript cannot
    supply the turn identity. *)

val stream_usage_text : keeper_name:string -> t option -> string option
(** The token counters the request now streaming reported so far, as clauses
    ([tokens: in 1200 · out 340]). Counters the provider did not report are
    left out rather than drawn as zero, and [None] means nothing was reported
    at all, so the row is unchanged from before this was measured. Another
    keeper's transcript reports nothing. *)

(** The recorded reply (KEEPER_REPLY_DETAILS): the visible text, the typed
    outcome, and the turn it was recorded under. *)
type reply =
  { reply_text : string
  ; reply_outcome : Masc.Keeper_turn_outcome.t
  ; reply_turn_ref : string
  }

val reply : t -> reply option
(** The recorded reply, once the turn has one. Not a trail item. For
    [Visible_reply] the text is already in the trail: the server streams it as
    deltas and, when nothing streamed, chunks the reply at the end. For the
    four control outcomes ([Continuation_checkpoint],
    [Terminal_effect_settled], [Awaiting_gate_approval], [No_visible_reply])
    nothing is chunked, so the reply text lives only here. {!drawn} is the one
    place both are reconciled into rows. *)

val turn_status_text :
  reply:string -> turn_ref:string -> Masc.Keeper_turn_outcome.t -> string
(** The one line a turn's ending reads as: the reply itself for a
    [Visible_reply] with text, otherwise a sentence naming the outcome and the
    turn. The strict whole-body decode and the log projection both draw a
    turn's last row through this, so a turn watched live and one read back
    end in the same words. *)

(** One row of a turn as the pane draws it. *)
type drawn =
  | Drawn_thinking of string list
  | Drawn_skill of skill_activity list
  | Drawn_tools of tool_block
  | Drawn_text of string  (** A reply stretch as it streamed. *)
  | Drawn_reply of string
      (** The recorded visible reply, standing where the current attempt's
          last streamed stretch was: the record is the store's text for the
          turn's terminal message, so it is the text drawn there. *)
  | Drawn_status of string
      (** How a turn without visible reply text ended, from the recorded
          reply through {!turn_status_text}. *)

type drawn_item =
  { superseded : int option
        (** [Some attempt] when a later runtime attempt superseded this row;
            [None] on the current attempt's rows. *)
  ; superseded_runtime_id : string option
        (** The runtime_id that served this superseded row, if known. *)
  ; drawn : drawn
  }

val drawn : t -> drawn_item list
(** The trail flattened -- a superseded block's rows in place, tagged with
    their attempt -- and reconciled with the recorded reply. Without a reply,
    the trail as it is. The recorded reply is the terminal message's text, not
    the whole turn's, so with a [Visible_reply] it stands for the current
    attempt's last text stretch only: that one stretch is replaced by one
    [Drawn_reply] carrying the record's text (appended when nothing
    streamed); earlier stretches -- the turn's earlier rounds -- stay as they
    streamed. The reply is this turn's because the log this transcript
    projects is one operation's and both the stream and the journal reach it
    by that id; the two texts are not compared. With a blank [Visible_reply]
    or any control outcome, one [Drawn_status] is appended and the streamed
    rows stay.

    A skill item whose read call has a record from {!note_skill_activity} is
    drawn as that record, unless the item is [Skill_failed]: the server
    records a composition's delivery from an error tool result too, so a
    record cannot turn a call the stream saw fail into a finished read.
    Records no skill item carries form one more [Drawn_skill], ahead of the
    stretch the reply stands for, or ahead of the appended reply or status
    row when no stretch streamed. *)

val of_log : now:float -> Masc_tui_keeper_chat_log.t -> t
(** The transcript a log projects to: {!create} from the log's identity, then
    {!apply} over every entry in order with the one [now] given. Equal to the
    transcript that grew with the same deltas in trail, text, thinking,
    attempt, phase, tool rows and reply. Not in the status rows: a tool call's
    [started_at] is the [now] of its [apply], so a re-fold dates every call to
    the re-fold and the progress row's ages and oldest-open-call choice can
    differ. Log entries carry no arrival time yet; the reload task adds one
    before it draws a re-folded turn's status row. *)

val tool_rows : t -> string list

(** One line per tool call, in stream order, the way the pane draws them: a
    marker for how far the call got, the tool's name, and the argument it is
    known by.

    The calls only: {!tool_projection.header} is a rollup over them, not one
    of them, and a caller counting steps would count one too many.

    This is the [Full] compatibility accessor for the current pane. New live
    and history consumers carry {!tool_block} to the render boundary and call
    {!project_tool_block} explicitly. *)
(** How a status row reads. *)
type approval_outcome =
  | Approved
  | Denied
  | Timed_out
  | Displaced
  | Approval_other of string

val approval_outcome_to_string : approval_outcome -> string

type status_kind =
  | Progress  (** How the turn is going. *)
  | Answer_needed
      (** The turn is held and the operator's key is what releases it. Kept
          apart from [Attention] because it is the one row that cannot be
          folded away: see [status_row_survives_folding]. *)
  | Attention  (** Something an operator has to know about. *)
  | Approval of approval_outcome
      (** How a held tool decision settled. This is deliberately not a tool
          success/failure: approval answers whether execution was allowed,
          while the tool row separately says whether execution returned. *)

val status_row_survives_folding : status_kind -> bool
(** Whether the row is still drawn when the turn dashboard is folded.

    The pane folds to its progress line and a count. The progress row is that
    summary, and a row asking the operator for something cannot go behind a
    key they have no reason to press -- the turn would sit held with nothing
    on screen saying so. The rest is history the operator can ask for.

    Exhaustive over [status_kind] on purpose: a new kind has to say which
    side it is on rather than inherit an answer. *)

val awaiting_approval : t -> awaiting_approval option
(** The call the turn is held at, if any. One at a time: the turn cannot reach
    a second call while it is waiting on this one. *)

val status_rows : now:float -> t -> (status_kind * string) list
(** The status rows the chat pane draws for this turn.

    Returned as a list rather than drawn directly because the pane's row
    budget has to know how many there are before it lays the pane out, and the
    budget answering differently from the drawing is how the unavailable row
    once went missing while the send hint still read Enter:send
    (see [keeper_message_status_rows]). One list, counted and drawn.

    The progress row carries the turn's age, measured against [now] rather
    than a clock read here so a test can state the instant. A [now] before
    [started_at] drops the age instead of printing a negative one. *)
