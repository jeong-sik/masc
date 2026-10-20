(** What is coming next, and what is waiting on the operator.

    Both facts were already on the screen somewhere, and neither was where the
    question gets asked. The next scheduled wake is computed by the server,
    decoded into [scs_next_due_iso], carried into the state -- and drawn only
    inside the Schedules surface, which you have to leave the chat to reach.
    This workspace answers it today by paying a keeper turn every 45 minutes
    to read the list out loud (schedule ["edgar-45min-check"], cron
    ["45 8-23 * * *"], "다음 일정과 해야 할 일을 알림으로 전달하시오").

    The strip is one row above the composer and holds the next wake. It is not
    drawn at all when nothing is scheduled -- the rule the surface strip's ring
    counts already follow, where an always-on badge would be texture rather
    than information. What waits on the operator is {!waiting_label}, which the
    surface strip at the top of every frame draws.

    {!rows_taken} is how that decision reaches both the frame and the keypress
    bound. A row the drawing adds while the bound counts rows without it is
    what put the Changes list out of reach of its own arrow keys, and the two
    read the same number here so it cannot happen again. *)

(** Whether a schedule is still ahead of the operator.

    The wire says status as a string. It is parsed here into the only question
    the strip asks, so a status nobody recognised stays off the strip instead
    of being defaulted onto it -- an unknown row is not a due row. *)
type standing =
  | Coming
  | Settled
  | Unrecognised of string

val standing_of_wire : string -> standing

type scheduled =
  { at_iso : string
        (** RFC 3339, as the wire sends it. The time is a field of the
            scheduled row rather than an option beside it: a row on the clock
            half of the strip has a clock. *)
  ; standing : standing
  ; who : string
        (** [payload_keeper_name] when present, otherwise the unparsed
            [payload_target] from an older server. *)
  ; what : string  (** [payload_summary], the title the operator wrote *)
  ; recurrence : string
        (** [recurrence_summary], e.g. ["every 3600s"]. The strip has no room
            for it; the overlay does, and it is the difference between "this
            happens every hour" and "this happens once". *)
  }

type awaiting =
  { asked_by : string
  ; tool_call_id : string
  ; question : string
  ; asked_at : float
  ; timeout_sec : float
        (** A held call is denied when the wait runs out, so the overlay says
            how long is left. Fields rather than an option: every held call
            the registry reports carries both. *)
  }
(** A keeper blocked until the operator answers. No time on purpose: the
    answer is due now, and a countdown would read as permission to wait. *)

type stalled =
  { task_id : string  (** the task the row is about, so a key can open it *)
  ; what : string
        (** The one line {!Operator_task_attention.summary} wrote. The sentence
            is made there rather than here so the three surfaces that draw this
            row cannot describe it three ways. *)
  ; since_iso : string  (** when it started waiting on the operator *)
  }
(** A task whose only exit belongs to the operator: work held by an agent with
    no Keeper queue, or a Keeper record that does not decode. *)

type goal_to_confirm =
  { goal_id : string  (** the Goal the row is about, so a key can open it *)
  ; title : string
  ; since_iso : string
        (** when the Goal last changed. That is when its proof was recorded
            unless its priority or due date was edited after that. *)
  }
(** A Goal the verifier proved. Its last step is the operator's confirmation
    (constitution, goal completion), so it waits on the operator. *)

type open_question =
  { ask : Masc.Tui_decode_asks.ask_key  (** the ask the row is about, so a key can open it *)
  ; asked_by : string  (** the Keeper's name or the installation's title *)
  ; first_question : string option
        (** The first question's prompt, as the asker wrote it. [None] for an
            ask that carries no question; the row then says only who asked. *)
  ; asked_at : float
  }
(** An ask a Keeper or an installation put to the operator that nobody has answered or withdrawn.
    One row per ask, however many questions it holds: the operator answers an
    ask as one draft and one submit, so the ask is the unit of waiting. *)

(** A list as the state holds it. An empty list is an answer only once it was
    read: before the first answer, and after a read that failed with nothing
    earlier to show, the overlay said "nothing is scheduled" about a list no
    one had seen. *)
type 'row reading =
  | Not_read  (** nothing has answered yet *)
  | Read_failed of string
      (** the read failed and there is no earlier answer to show; the string is
          why, as the state holds it. The overlay sanitizes it before fitting
          it to a terminal row; projecting and counting rows do not render it. *)
  | Read of 'row list

type t

val project :
  scheduled:scheduled reading ->
  awaiting:awaiting reading ->
  asking:open_question reading ->
  confirming:goal_to_confirm reading ->
  stalled:stalled reading ->
  t
(** Keeps the earliest {!Coming} row and counts the rest. Rows that are
    settled or unrecognised are not on the strip. [stalled] arrives in the
    order the projection sorted it, longest wait first. *)

val rows_taken : t -> int
(** [1] while a wake is coming, [0] otherwise. The surface gets the row back
    when it is [0]. Work waiting on the operator does not take this row: it is
    on the surface strip, which every frame has. *)

val waiting : t -> int
(** Held calls, open questions, Goals to confirm and stuck tasks together. An
    open ask counts once however many questions it holds. A list that was not
    read adds nothing. *)

val waiting_label : cells:int -> t -> string
(** The badge for the surface strip, as plain text; styling belongs to the
    renderer. It names what waits, by kind and in that order of attention --
    questions, held calls, Goals to confirm, stuck tasks -- led by the [;] key
    that opens the panel, and is [""] when nothing waits.

    The longest of three spellings that fits [cells] is returned: the
    sentence, the kinds alone, the {!waiting} total alone. The total is
    returned even when it does not fit, so the badge never disappears; the
    caller makes room for it. *)

val strip :
  now:float -> localtime:(float -> Unix.tm) -> cols:int -> t -> string option
(** The row above the composer: the next wake, or [None] exactly when
    {!rows_taken} is [0].

    A wake that falls on a later day says so. Rendering tomorrow's 08:00 as a
    bare ["08:00"] at 23:50 reads as eight minutes away. *)

(** {1 The overlay}

    The strip answers "is there anything"; this answers "what". They differ on
    the empty case: the strip draws nothing, because an always-on row saying
    nothing is happening is texture. The overlay says so in words, because the
    operator pressed a key to ask and a blank panel would read as a failure to
    load. *)

type tone =
  | Heading
  | Wake
  | Question
  | Quiet
  | Failed  (** a read that did not answer, drawn like a failure elsewhere *)

(** Where a row leads. Most lead nowhere -- headings, spacers, the note an
    empty section draws -- and a row that leads nowhere is one the cursor does
    not stop on. Before this the panel led nowhere at all: it counted the work
    waiting on the operator and had no way to reach any of it. *)
type destination =
  | Nowhere
  | Keeper_holding of { keeper : string; tool_call_id : string }
      (** The exact held call; one Keeper can have several awaiting answers. *)
  | Ask_to_answer of Masc.Tui_decode_asks.ask_key
      (** The ask, answered on Approvals where every question is answered. *)
  | Goal_to_confirm of string  (** the Goal, confirmed on its own detail *)
  | Stuck_task of string  (** the task, read on its own detail *)

type line =
  { tone : tone
  ; text : string
  ; goes_to : destination
  }

val overlay :
  now:float -> localtime:(float -> Unix.tm) -> cols:int -> t -> line list
(** Every wake still coming, earliest first, then everyone blocked on the
    operator, then the questions Keepers asked and nobody answered, then the
    Goals waiting for the operator's confirmation, then the tasks stuck on
    them. Every row of every section, not just the one the strip
    names; the panel scrolls. A section whose list was not read says that
    instead of saying it is empty. *)

val target_indexes : line list -> int list
(** Indexes of the rows Enter can act on, in display order. The cursor moves
    over these, not over prose. *)

val equal_destination : destination -> destination -> bool
(** Whether two destinations are the same target. An ask is compared by
    [Masc.Tui_decode_asks.equal_ask_key], so an installation's new title is
    the same ask. *)

val selected_index : line list -> selected:destination -> int option
(** The current row of the selected identity. [None] for [Nowhere] or an
    identity removed by a refresh; a different row never inherits selection. *)

val selected_line : line list -> selected:destination -> line option
(** The same identity the renderer highlights, revalidated against the latest
    reading before Enter opens it. A removed selection opens nothing. *)

type step = Next | Previous

val step : line list -> selected:destination -> step -> destination
(** Explicit cursor movement between actionable identities. An absent or
    removed selection starts at the first target; no targets yields [Nowhere].
    Merely replacing a reading does not call this or select a neighbour. *)
