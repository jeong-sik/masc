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

type skill_activity = private
  { skill_name : string
  ; skill_tool_use_id : string option
  ; turn_ref : string option
  ; content_revision : string option
  ; runtime_id : string option
  ; state : skill_state
  ; actions : string list
  ; detail : string option
  }

val make_skill_activity :
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

val skill_rows : full:bool -> skill_activity -> string list
(** Markdown rows for one Skill card. The first row emphasizes the exact Skill
    name and lifecycle; [full] additionally exposes actions and exact proof
    coordinates. *)

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
  ; rows : string list
  ; hidden_activity_rows : int
  ; omitted_steps : int
  ; summary_outcome : tool_outcome option
        (** The outcome the folded summary row stands for, and [None] when
            nothing was folded.

            A chat body is sanitized before it is drawn -- a row cannot carry
            an escape into the terminal -- so a marker inside the text cannot
            be coloured, and the row's own style is the only channel a reading
            of state has. Folding is what makes that channel matter: [Full]
            gives every call a row and a glyph of its own, while a fold puts
            six calls behind one line where "1 failed" sits mid-sentence in
            the same colour as "5 returned".

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

val tool_block : ?omitted_steps:int -> tool_activity list -> tool_block

val project_tool_block : tool_projection_mode -> tool_block -> tool_projection
(** The only tool-row formatter. [Full] preserves the existing one-row-per-call
    output. [Compact] folds two or more calls into one outcome summary and
    states the exact number of hidden detail rows. Neither mode fabricates
    missing identity, duration, outcome, or omitted transcript steps. *)

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
val started_at : t -> float
(** The dispatch instant supplied to {!create}. Exposed as typed timeline
    input so a live turn keeps its original civil-hour rail while it grows. *)

val apply : now:float -> t -> Masc_tui_keeper_chat_live.delta -> unit
(** [now] stamps a tool call as it opens, so the progress row can say how long
    the call in flight has been open rather than only how long the turn has. *)
(** Fold one delta in. Tool deltas join only by their server-owned stream
    occurrence. Provider ids are optional correlation data; an unknown
    occurrence is reported unreadable rather than attached by position. *)

val note_interrupt : t -> interrupt -> unit

val phase : t -> phase
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
(** In the order the stream opened them. *)
val unreadable : t -> unreadable option

(** One stretch of the turn, in arrival order. A tool-call round interleaves
    reasoning, calls and reply text; {!text}, {!thinking_lines} and
    {!tool_rows} answer the totals, this answers the order, which is what a
    reader follows a long turn by. Tool stretches stay typed; text and
    reasoning strings are terminal-safe. *)
type trail_item =
  | Trail_thinking of string list
      (** Non-blank reasoning lines of one contiguous stretch. *)
  | Trail_skill of skill_activity
      (** A Skill-as-tool call separated from generic tools so the chat can
          give its delivery/usage semantics a distinct visual treatment. *)
  | Trail_tools of tool_block
      (** One contiguous run of typed calls. A call keeps updating its facts
          (arguments, outcome) after later stretches open. *)
  | Trail_text of string  (** One contiguous stretch of reply text. *)
  | Trail_superseded of
      { attempt : int
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

val reply : t -> (string * Masc.Keeper_turn_outcome.t) option
(** The recorded reply and its typed outcome (KEEPER_REPLY_DETAILS), once
    the turn has one. Not a trail item. For [Visible_reply] the text is
    already in the trail: the server streams it as deltas and, when nothing
    streamed, chunks the reply at the end. For the four control outcomes
    ([Continuation_checkpoint], [Terminal_effect_settled],
    [Awaiting_gate_approval], [No_visible_reply]) nothing is chunked, so the
    reply text lives only here; the pane draws those turns' status row from
    this accessor (today via the strict decode in [apply_keeper_chat_result];
    from the log once settle commits the log). A streamed [Visible_reply] can
    also differ from the trail's text when the server stripped control tokens
    from the visible reply; the same projection step reconciles that. *)

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
  | Attention  (** Something an operator has to know about. *)
  | Approval of approval_outcome
      (** How a held tool decision settled. This is deliberately not a tool
          success/failure: approval answers whether execution was allowed,
          while the tool row separately says whether execution returned. *)

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
