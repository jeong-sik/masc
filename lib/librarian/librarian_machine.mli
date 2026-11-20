(** What one event does to one Keeper's writer
    (RFC librarian-call-only-proposes §9.2, §9.3): an ask, a turn that
    closed, the pulse, a new declaration, a direct write and an operator's
    act, in each state of an open or stopped store.

    Every function is synchronous and returns the next value with the
    answer. None waits for a model. The commits and the reads that start the
    next ask happen inside them, and the store and the turn log do the I/O.
    The fiber that owns a Keeper's writer boots first and then calls one of
    these for each event it takes from its mailbox, where it cannot be
    cancelled; events that arrive during the boot wait there. Only the ask
    runs in a fiber of its own: {!fiber_change} says how to keep that fiber
    in step with the value.

    [Booting] and [Retired] are {!Librarian_writer.status}'s. An ask reads at
    the width the writer's narrowing gives ({!Librarian_width}, §7.6). What
    the bottom learned and [Refused_at_bottom] come with the bottom layer
    (§20 L7): here a question of one item that the lane refuses leaves the
    writer [Resting], as a lane that answers nothing does.

    {b The model.} [specs/bug-models/LibrarianWriter.tla] (§21) has the same
    transitions. Its names are these:

    {v
    model                             here
    "Idle" "Asking" "Resting"         Idle, Asking, Resting
    "Stopped", Stop(m, why)           Stopped
    "RaB"                             none: the width layer's Refused_at_bottom
    "Booting" "Retired" "Absent"      Librarian_writer.status, Librarian_writers
    HandleHint                        decide _ Turn_closed
    PulseIdle, PulseResting           decide _ Pulse
    HandleAsk                         decide _ (Ask_ended _)
    Declaration                       decide _ (Declaration_changed _)
    Write, HandleWrite                write
    Resume                            resume
    Adopt                             adopt
    BootFinish                        booted
    FreshMem(m.lane)                  booted from the lane and the last number only
    Start(m, c, fb)                   the next ask, inside these functions
    Committing                        a store commit and the rule of a failed one
    m.lane, Q(l)                      t.lane, the lane value's question side
    m.askNo, m.askLane, m.rs          asking.ask, asking.lane, asking.removed_since
    m.seen, FileLen                   Idle's seen_length, the turn log's length
    held                              Librarian_memory_lane.lane_held
    c.gid                             t.last_ask
    msg.no, msg.res                   Ask_ended's ask and result
    v}

    The narrowing's own rules are [specs/bug-models/LibrarianWidth.tla]'s;
    {!Librarian_width} names them.

    The model's results map to {!Librarian_read_result.t}: ["answer"] is
    [Answered], ["nothing"] [Nothing_to_ask], ["missing"] [Nothing_readable],
    ["span"] [Span_unknown], ["diverged"] [Memory_diverged] and
    [Snapshot_fault] (the model's [snapBad] is a snapshot that does not
    decode, and it stops the store either way), ["fault"]
    [Input_fault], ["failed"] [Ask_failed], and the lane results
    ([LaneRes]) are [No_answer]. *)

module Digest := Agent_core.Checkpoint_objects

(** Where one Keeper's files are: the snapshot and the commit log in
    [memory_dir], the turn log in [turns_dir]. *)
type place =
  { memory_dir : string
  ; turns_dir : string
  ; keeper_id : string
  }

(** The lane value declared now, and the registry's resolution of it that a
    walk and {!Librarian_memory_lane.lane_held} read. *)
type declared =
  { value : Librarian_memory_lane.t
  ; resolved : Runtime_exact_output_registry.resolved_lane
  }

(** The ask that is out. *)
type asking =
  { ask : int (** Its number. A writer never gives a number twice. *)
  ; since : float (** When it started. *)
  ; lane : declared
  (** The declaration it started with: the lane value its question carries
      and the resolution its walk goes through. *)
  ; removed_since : (string * int) list
  (** Every fact a direct write removed while it was out, with the [seq] of
      the commit that removed it, in commit order: what
      {!Librarian_plan.of_answer} takes. *)
  ; asked : Librarian_read_result.asked
  (** [Read_range]: the width it reads at, {!Librarian_width.next} of the
      narrowing when it started; a refusal goes onto the level this names.
      [Read_item_alone]: the head item alone, asked only on the bottom's
      verdict. *)
  ; bottom : Librarian_bottom.t
  (** The head item's size facts when it started. The ask calls no slot
      that has one under its question's id. *)
  }

type state =
  | Idle of
      { store : Librarian_store.t
      ; seen_length : int option
      (** The turn log's length when the last next ask found nothing to
          ask. [None]: it could not be read, and the next pulse reads the
          turn log. *)
      }
  (** Nothing is unread, or there is no lane value. *)
  | Asking of
      { store : Librarian_store.t
      ; asking : asking
      }
  | Resting of Librarian_store.t
  (** Something is unread and the last ask ended without a commit. The next
      pulse asks again unless every slot is held. *)
  | Refused_at_bottom of Librarian_store.t
  (** Every slot the lane declares gave a size fact to the head item's
      question and not every one was for the input (§7.4). No slot is left
      to ask and none says the item fits below, so nothing is asked or read
      until an event can change the question: a direct write, another lane
      value, or the operator. *)
  | Stopped of Librarian_store.stop

(** What the writer holds in memory beside the state (§9.1). Nothing of it
    is on disk. *)
type t =
  { state : state
  ; lane : declared option (** [None]: no lane value is declared. *)
  ; last_ask : int (** The last number an ask was given. *)
  ; narrowing : Librarian_width.t
  (** The ranges the lane refused. A boot starts with none; another lane
      value and an adoption empty it. A pulse, a direct write and a
      [Resume] of a rest leave it as it is. *)
  ; bottom : Librarian_bottom.t
  (** The head item's size facts. A boot starts with none; a commit that
      moves reading and a [Resume] empty it. Another lane value and an
      adoption leave it: a fact is held under one question's id and one
      slot's key, so a fact about a question or slot not asked now is not
      found, and the item alone is the same question under every Memory. *)
  }

(** The store's boot (§8.6): open, or the reason it stopped. *)
val boot : place -> at:float -> (Librarian_store.t, Librarian_store.stop) result

(** The value of a writer whose boot ended in [opened]: [Stopped], or the
    next ask on the store it opened. A writer is made with this, and a
    resumed one is made again with it: nothing of the value before the boot
    is kept but [lane], the declaration the writer holds, and [last_ask]. The
    narrowing starts empty.

    [last_ask] is the last number this writer's mailbox can still hold an
    answer for: 0 for a new writer. A resumed writer passes its own, because
    an answer to an ask it cancelled can still be in the mailbox, and a
    number given again would make that answer current. *)
val booted
  :  place
  -> at:float
  -> lane:declared option
  -> last_ask:int
  -> (Librarian_store.t, Librarian_store.stop) result
  -> t

(** How an ask ended. *)
type ended = Read_ended of Librarian_read_result.t

type event =
  | Turn_closed (** A [Closed] or a [Reset] line was appended to the turn log. *)
  | Pulse
  | Ask_ended of
      { ask : int
      ; result : ended
      }
  | Declaration_changed of declared option

(** One event (§9.3). A [Declaration_changed] whose lane value is the one
    held does not reach the table: the registry and the runtime table send
    it on every publication. Its resolution replaces the held one and
    nothing else changes, so the next ask and a rest's held check go through
    the target the registry published last (a new credential or body
    timeout comes with the same value). One with another value empties the
    narrowing, in every state.

    {b The next ask} (§9.2). The turn log's length is read first. With no
    lane value the writer is [Idle] with that length. Otherwise the turn log
    is read from the tail ({!Librarian_unread.read} up to the first unit
    with items): something unread is [Asking] with the number after
    [last_ask], at the width {!Librarian_width.next} gives, with the size
    facts held; nothing is [Idle] with the length read first, so a turn
    appended during the read is not counted as seen. The head item alone is
    asked the same way, only on the bottom's verdict below.

    {b A late answer.} An [Ask_ended] whose number is not the current ask's
    is dropped in every state. One that carried an answer is counted
    ([LibrarianLateAnswers], by keeper).

    {b A failed commit} (§9.2). A line on disk whose snapshot was not
    written stops the store as [Store_unwritable]. No line stops it for the
    reason the store gives. Effects that make no snapshot leave the store
    as it was and the writer [Resting]: asking again at once would ask the
    same question.

    {v
    state     event                              next
    Idle      Turn_closed                        the next ask
    Idle      Pulse                              Idle when the length is the one seen;
                                                 else the next ask
    Idle      Declaration_changed                held; the next ask
    Asking    Turn_closed, Pulse                 Asking
    Asking    Ask_ended, the current ask         the table below
    Asking    Declaration_changed, another       held; the next ask: the ask is cancelled
              question side or no lane value
    Asking    Declaration_changed, slots only    held; Asking: the answer is still committed
    Resting   Turn_closed                        Resting
    Resting   Pulse                              Resting when every slot is held; else the next ask
    Resting   Declaration_changed                held; the next ask
    Refused_at_bottom  Turn_closed, Pulse        Refused_at_bottom
    Refused_at_bottom  Declaration_changed       held; the next ask
    Stopped   Turn_closed, Pulse                 Stopped
    Stopped   Declaration_changed                held; Stopped
    any       Ask_ended, not the current ask     as it was: a late answer
    v}

    The current ask's result:

    {v
    Answered          planned ({!Librarian_plan.of_answer} with removed_since),
                      committed ({!Librarian_store.commit_read}); the narrowing counts
                      what it passed; the next ask
    Nothing_to_ask    the next ask
    No_answer         The slots the lane declares now are the ones read.
                      More than one item: one of them refused, narrowed by what the
                      question carried; the next ask. None refused: rest.
                      One item, or the item alone: its sized refusals are learnt
                      ({!Librarian_bottom.learn}). A question made against another
                      snapshot than the tail's now: the next ask. Otherwise
                      {!Librarian_bottom.fold} over the lane now:
                        Input, with Memory     the item alone is asked at once
                        Input, alone           Skip (Item_exceeds_window missing)
                                               committed at reach; the narrowing counts
                                               what it passed; the next ask
                        All_not_input          Refused_at_bottom
                        Not_all                rest
                      Rest: Resting, or the next ask when none of them is in the
                      result and the lane value is not the one the ask started with
    Nothing_readable  Skip (Content_missing missing) committed at reach; the narrowing
                      counts what it passed; the next ask
    Span_unknown      Skip (Unknown_span {before; after = reach.covered}) committed
                      at reach; the next ask
    Memory_diverged   Stopped (Log_diverged _)
    Snapshot_fault    Stopped ({!Librarian_store.stop_of_snapshot_fault}): absent and
                      not a snapshot are Memory_unreadable, a failed read
                      Store_unwritable
    Input_fault       Resting
    Ask_failed        Resting
    v} *)
val decide : place -> t -> at:float -> event -> t

(** Why a Keeper's Memory takes neither a write nor an act. *)
type unavailable =
  | Store_stopped of Librarian_store.stop
  | Keeper_retired
  (** The Keeper is not registered, so it has no writer. No state here
      answers this: a writer that retires ends, and whoever looks for the
      Keeper's writer finds none. *)

type write_answer =
  | Written of Librarian_log.commit (** The line that was committed. *)
  | Already_held
  | Already_done
  | Already_absent
  | Refused of Librarian_direct.refusal
  | Not_a_snapshot of Librarian_envelope.refusal
  (** The plan's effects do not make a snapshot. Nothing was written. *)
  | Unavailable of unavailable

(** A direct write (§8.5), committed at once in every state of an open
    store: it does not wait for an ask.

    - The write is planned against Memory and, when the plan writes,
      committed. The state stays what it was. An answer that writes no line
      leaves the value as it was.
    - [Asking]: the facts the commit removed join [removed_since] with its
      [seq], so the answer cannot bring back what was removed while it was
      asked.
    - [Refused_at_bottom]: a commit is followed by the next ask. Memory
      changed, so the head item with Memory is another question (§9.3).
    - A commit that finds the snapshot or the log other than it left them
      stops the store, and the write is [Unavailable (Store_stopped _)].
    - A commit whose line is on disk and whose snapshot is not is answered
      [Written]: it is committed. The store stops as [Store_unwritable] and
      the next boot writes the snapshot from the line.
    - [Stopped s]: [Unavailable (Store_stopped s)]. *)
val write
  :  place
  -> t
  -> at:float
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> t * write_answer

type act_refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Act_unavailable of unavailable

type act_answer =
  | Done
  | Not_done of act_refusal

(** An operator's [Resume] (§9.3, §12.4).

    - [Stopped]: [boot] once more, and {!booted} makes the value again from
      what it returns. The writer passes the boot it ran when it started,
      which takes its lock before it opens the store. [Done] says the boot
      ran; the state says how it ended.
    - [Resting], [Refused_at_bottom]: the head item's size facts are emptied
      and the next ask follows, which calls every slot again.
    - [Idle], [Asking]: [Not_done Nothing_to_resume], and [boot] is not
      called. *)
val resume
  :  place
  -> boot:(unit -> (Librarian_store.t, Librarian_store.stop) result)
  -> t
  -> at:float
  -> t * act_answer

(** An operator adopts the snapshot file of a store stopped as
    [Log_diverged] or [Log_unreadable] (§8.7); the narrowing and the size
    facts are emptied and the next ask follows. A store
    stopped for another reason is [Act_unavailable (Store_stopped _)]:
    booting again is its way out. A store that is not stopped is
    [Not_stopped]. A refusal leaves the value as it was. *)
val adopt
  :  place
  -> t
  -> at:float
  -> by:string
  -> observed:Digest.digest
  -> t * act_answer

(** What the writer's fiber does to the ask's fiber after one step. *)
type fiber_change =
  | Keep (** The same ask is out, or none is and none starts. *)
  | Start of asking
  | Cancel (** The ask that was out is not the current one any more. *)
  | Cancel_then_start of asking

(** Read from the numbers of the ask before and after the step: the same
    number is [Keep], another is [Cancel_then_start], an ask only before is
    [Cancel], only after is [Start]. Cancelling an ask that has ended does
    nothing. Whether to ask is decided only by the state. *)
val fiber_change : before:t -> after:t -> fiber_change
