(** Keeper_carried_front — a position in the keeper's checkpoint history
    where a request's carried range can open (RFC
    keeper-context-window-in-tokens §10.4, §13.4, §13.6).

    Where a request starts is chosen in one place,
    {!Keeper_turn_driver_try_provider.choose_range_start}: where the
    Keeper's Memory writer has read to in this history ({!Covered}), else a
    seed this history still holds, else where the last completed turn on
    this history ended ({!Turn_start}). The read end yields to a later start
    the provider accepted, and the request then reports where that start
    came from ({!Carried}). The turn's
    composition and the next-request forecast both ask it. This module holds
    the vocabulary of that choice -- the seed, the turn start, and the
    {!origin} a request reports -- and the reads that produce a seed.

    A seed is the front of a range already carried: the oldest atom that
    request carried, or the witnessed end of a history it omitted entirely. It is a position in the keeper's checkpoint history --
    the trace -- and every runtime cuts its request from that one history,
    so a position measured on one names the same atom on the next. While the
    process holds a ledger for the (keeper, runtime) pair, the seed is the
    ledger's: the last request's observed front.
    Without one, it is the range the newest turn record joined to an actual
    provider response, whichever runtime observed it -- an official client's
    record counts the same history as an Agent Core one -- read as
    [total_atoms - transmitted_atoms]. A front a refusal moved in this turn
    ({!Turn_start_after_refusal}, {!This_turn_start_after_refusal}), or the
    size signal moved ({!Turn_start_at_max_context}), belongs to the turn and
    takes precedence over an older front in a later candidate's ledger.

    A front is a position witnessed by an opening-message digest
    ({!Runtime_model_input_tail_window.atom_opening_digest}): the front atom
    when any atom was carried, the preceding atom for an accepted empty
    range. A seed is used only while that witness matches ({!for_history}); the history's atom count is not compared. A
    history one unsaved atom shorter keeps the position, and a checkpoint
    purge that rewrote the message opening the front drops it. *)

type source =
  | Ledger  (** The pair's last observed request range. *)
  | Turn_record of { turn : int }
      (** The newest turn record on the trace with a request range joined to
          an actual provider response, whichever runtime ran it. The whole
          turn may still have ended in error after that response. *)
  | Turn_start_after_refusal
      (** The provider refused as too large a range that opened before the
          turn boundary -- at a seed, at the Memory writer's read end, or at
          a start the provider accepted past it: the front moved to the turn
          boundary, and the turn shares that position with its later
          candidates and lanes (RFC librarian-lifecycle §4.10, rule 1). *)
  | This_turn_start_after_refusal
      (** The range opened at the turn boundary was refused as too large
          too: the front moved to where this turn began (rule 8), and the
          turn shares that position with its later candidates and lanes.
          Rule 7 bounds it by where this turn began, not by the turn
          boundary. *)
  | Turn_start_at_max_context
      (** No provider refused anything: at the turn's first request the
          window stayed where the last request opened it, and that request's
          count plus the largest growth one turn made since the ledger
          started passed the request's input limit, the window less the
          output the request reserves. The front moved to the turn boundary
          for the rest of the turn, with no Librarian point or one at or
          before where the window opened. *)
  | Librarian_point_at_max_context
      (** As {!Turn_start_at_max_context}, with a Librarian point past where
          the window opened: the front moved to the end of what the
          Librarian read instead of the turn boundary, so the atoms the move
          drops are in memory. *)

type seed =
  { first_atom : int
  ; front : Model_input_front.t
        (** [At_atom] witnesses [first_atom]; [After_history] witnesses
            [first_atom - 1], the end of a successfully omitted history.
            [Empty_history] with [first_atom = 0] is an offered-empty
            history; with [first_atom > 0] it is a floor seed (#39013),
            whose position stands past every atom, and [for_history]
            drops it as [Front_atom_missing]. *)
  ; source : source
  }

(** Where a request with no absorbed point and no seed starts (RFC
    keeper-context-window-in-tokens §13.4), as {!Keeper_turn_driver_try_provider.turn_start}
    reads it from the keeper's turn log and checks it against the history in
    hand. *)
type turn_start =
  | Turn_boundary of { end_atom : int }
      (** The end of the last unit of the turn log on this history, which
          holds at least the closed messages the unit names. 0 when the log
          has no line: the short history of a new keeper, all of which goes
          out. *)
  | Turn_boundary_unknown of { reason : string }
      (** The log could not be read, its last unit ends on another trace, or
          the history holds fewer messages than the unit closed. Where this
          turn began is not known, and the request opens
          on the newest atom alone ({!newest_atom}) rather than on everything:
          §13.4 does not fold an unknown start into the whole history, and a
          short range costs one turn of context where a 16 MB one costs the
          turn. [reason] is what the reader said. *)

val turn_start_to_string : turn_start -> string
(** [boundary:<end_atom>] or [unknown:<reason>], for log lines. *)

type origin =
  | Carried of source
      (** The front came from a seed, and [source] is where the seed came
          from. With no read end it is a seed this history still opens with
          the same message. With one, it is the start the provider accepted
          on this history, when the range opens there and not at the read
          end (RFC librarian-lifecycle §4.10, rule 2): the newest
          response-observed turn record, or a front this turn held after a
          size refusal or the size signal. Which of the two a request took
          is its {!Keeper_turn_driver_try_provider.range_start}. *)
  | Covered of { end_atom : int }
      (** Where the Keeper's Memory writer has read to in this history
          (RFC librarian-call-only-proposes §11.1): the atoms before
          [end_atom] are in Memory and are not sent again. The working state
          the writer committed rides in their place when there is one. *)
  | Turn_start of { end_atom : int }
      (** No absorbed point and no seed: the range begins where the last
          completed turn on this history ended, so only this turn's own
          atoms go out and the atoms before them wait for the Librarian
          (§13.4). [end_atom] is that boundary as the turn log states it
          (§11.2), not the atom the range opened on: a boundary at or past
          the newest atom still carries that atom ({!clamp}). It is 0 on a
          history with no completed turn, where that is the short history a
          fresh keeper has. *)
  | Turn_start_unknown of { reason : string }
      (** No absorbed point, no seed, and the turn start could not be read
          ({!Turn_boundary_unknown}): the range opened on the newest atom
          alone. [reason] is what the boundary reader said. *)

val of_ledger : Keeper_model_input_ledger.t -> seed option
(** The ledger's front with the digest the ledger recorded for it; [None]
    when its last request carried no atom, which names no position. *)

(** Who composes a runtime's request, which says whose atoms a window it
    recorded counts. *)
type composer =
  | Composes_from_the_history
      (** An Agent Core binding: the request is cut from the keeper's
          checkpoint history, so its window is a range of atoms of that
          history. *)
  | Hands_over_its_own_list
      (** An official client: masc hands over a list and the client
          assembles the request. The window it records is still a range of
          the checkpoint history, because the cut masc measures runs over
          the same [agent.state.messages] the Agent Core path cuts; what the
          client does with the list afterwards is not in the record. *)
  | Not_materialized
      (** The catalog has no such runtime; which kind it was is unknown. *)

val composer_of_execution : Runtime_execution.t -> composer

val composer_of_runtime : Runtime_instance.t option -> composer
(** {!composer_of_execution} of a materialized runtime, {!Not_materialized}
    of [None]. Used to classify the forecast's current lane; historical
    response observations do not depend on the current catalog. *)

val composer_to_string : composer -> string

val of_records
  :  trace_id:string
  -> Turn_record.t list
  -> seed option
(** The highest [absolute_turn] of [trace_id] carrying
    [response_observed_model_input]. Different turn numbers may be in any
    input order. Input order affects ties: observations sharing a turn number
    must be chronological, oldest first, and the last entry wins. A direct
    retry can reuse a turn number. {!read_seed} passes singleton lists while
    traversing storage newest first, so it uses storage order instead.
    The producer joined this range to a response; the
    runtime can be removed or redefined in the current catalog without
    changing that fact. The joined runtime remains attribution, not a lookup
    requirement. A different trace is a different history; {!for_history}
    checks the selected position against the caller's current history. *)

type unreadable_records =
  { count : int  (** At least 1. *)
  ; first_reason : string
        (** The decoder's error for the oldest visited row that did not decode. *)
  }
(** JSON rows {!read_seed} read that {!Turn_record.of_json} refused. A line
    that is not JSON is skipped by the store reader before this count and is
    not in it. *)

type refused_start =
  { runtime_profile : string  (** The runtime whose typed refusal it was. *)
  ; first_atom : int  (** Where the refused range opened. *)
  ; front : Model_input_front.t
  ; turn : int
  }
(** The start of a request range a runtime refused
    ({!Turn_record.refused_model_input}). *)

type seed_read =
  { seed : seed option
  ; refused_start : refused_start option
        (** Set when the newest observation on this history is a refusal: no
            response-observed record is stored after it. Stored order, not
            the turn, decides, because a direct retry may reuse its turn
            number; a record that carries both answers its own refusal.
            [seed] is still the newest
            accepted range behind it, for the runtimes the refusal does not
            speak for (RFC-librarian-lifecycle §4.10). *)
  ; unreadable : unreadable_records option
        (** [None] when every record read decoded. A seed is looked for among
            the records that did, so [seed = None] with [Some _] here is
            "records unreadable", not "no record". *)
  ; boundary_error : string option
        (** The turn log, which defines the current history generation, could
            not be read: the file, a line that does not decode, or a line out
            of order. Kept separate from [unreadable], whose count is only
            for TurnRecord rows. A boundary error admits no seed. *)
  }

val no_seed_read : seed_read
(** No seed, unreadable record, or boundary error: a caller that reads no
    records. *)

val warn_seed_read_failures
  :  keeper_name:string
  -> runtime_id:string
  -> seed_read
  -> unit
(** Writes one WARN on [keeper_name]'s log for [unreadable] and one for
    [boundary_error], each when set, naming [runtime_id], the runtime whose
    request the read started. A read with neither writes nothing; [seed] is
    not reported. The Agent Core attempt and the official-client host both
    report their reads here, so one failure reads the same in either lane. *)

val seed_read_of_rows
  :  trace_id:string
  -> Yojson.Safe.t list
  -> seed_read
(** {!of_records} over the rows that decode as turn records, with the rows
    that do not counted and [refused_start] decided as {!read_seed} decides
    it, rows oldest first. *)

val read_seed
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> seed_read
(** The last stored response observation in the current history generation,
    scanning newest first until a match, a different trace, or a turn at or
    below the generation boundary the Keeper's turn log states
    (RFC librarian-call-only-proposes §11.2). That boundary is set by the
    last [Reset] of this trace (its [after.trace]) whose cause is
    [Announced Cleared] or [Unannounced]; an [Announced Recovered] reset
    keeps the history and sets none. It is the highest turn number, read
    from the [Opened] line's [turn_ref], among this trace's turns closed
    before that [Reset], whatever their outcome: the same [absolute_turn]
    coordinate as TurnRecord, never a wall-clock comparison. A turn that
    closes after the [Reset] is above it, the turn whose tool cleared the
    history among them. With no such [Reset], or no turn closed before it,
    there is no boundary. Unobserved rows do not hide an older seed within
    that generation. Storage order also resolves direct retries that reuse a
    turn number. Unreadable rows visited before the match are counted; rows
    older than the match or generation boundary are not read. A turn log
    that cannot be read, holds a line that does not decode, or breaks the
    line order ({!Keeper_turn_log.step}) returns no seed and is reported in
    [boundary_error]. Reads on the calling fiber; the turn driver calls it
    once per provider attempt, and only while the pair has no ledger. *)

(** Why {!for_history} dropped a seed. *)
type dropped_front =
  | Front_atom_missing
      (** The history has no atom at [first_atom], or the seed names no front
          at all: a floor seed (#39013) always drops this way, whatever the
          history holds. *)
  | Front_message_differs
      (** The atom at [first_atom] opens with another message: atoms before
          the front were removed or replaced. *)

val for_history
  :  digest_at:(int -> string option)
  -> seed
  -> (seed, dropped_front) result
(** The seed while its opening atom or history-end witness matches the
    history in hand; otherwise why not. A floor seed ([Empty_history] with
    [first_atom > 0], #39013) names a position past every atom and always
    drops as [Front_atom_missing]. A dropped position names no atom of this
    history, and carrying the newest atom alone from there would never widen
    again, so the caller starts over as with no seed. *)

val refused_start_for_history
  :  digest_at:(int -> string option)
  -> refused_start
  -> (refused_start, dropped_front) result
(** {!for_history} for a refused start: the refusal speaks for this history
    only while the atom the refused range opened on is still that message. *)

val dropped_front_to_string : dropped_front -> string

val clamp_seed : atom_count:int -> seed -> int
(** An accepted empty boundary may sit just past the newest atom. *)

val clamp : atom_count:int -> int -> int
(** The front as a position in a history of [atom_count] atoms: at least 0,
    at most the newest atom, so the range always carries the turn. *)

val newest_atom : atom_count:int -> int
(** The newest atom of a history of [atom_count] atoms, 0 when it has none:
    where a range opens when the turn start is unknown. *)

val warn_range_opens_on_newest_atom : keeper_name:string -> reason:string -> unit
(** The WARN a request logs when an unknown turn start is what opened its
    range, on the newest atom alone. Reading the turn start logs nothing: a
    turn reads it on every dispatch, and a seed or a Librarian point usually
    decides the range instead. *)

val warn_if_origin_is_unknown_start : keeper_name:string -> origin -> unit
(** {!warn_range_opens_on_newest_atom} when the request's range opened at
    [Turn_start_unknown]; nothing for any other origin. *)

val source_to_string : source -> string
val seed_to_json : seed -> Yojson.Safe.t
(** [first_atom], [front] and [source]. *)
val origin_to_string : origin -> string

val origin_to_json : origin -> Yojson.Safe.t
(** One object with a [kind], one per constructor: [ledger];
    [turn_record] with [turn]; [turn_start_after_refusal];
    [this_turn_start_after_refusal]; [turn_start_at_max_context];
    [librarian_point_at_max_context];
    [covered] with [end_atom];
    [turn_start] with [end_atom]; or
    [turn_start_unknown] with [reason]. *)
