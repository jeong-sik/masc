(** Keeper_carried_front — a position in the keeper's checkpoint history
    where a request's carried range can open (RFC
    keeper-context-window-in-tokens §10.4, §13.4, §13.6).

    Where a request starts is chosen in one place,
    {!Keeper_turn_driver_try_provider.choose_range_start}: a Librarian
    continuity snapshot that fits the history, else the Librarian's read
    position in it, else a seed this history still holds, else where the
    last completed turn on this history ended ({!Turn_start}). A Librarian
    point yields to a later start the provider accepted
    ({!Past_librarian_point}). The turn's
    composition and the next-request forecast both ask it. This module holds
    the vocabulary of that choice -- the seed, the turn start, and the
    {!origin} a request reports -- and the reads that produce a seed.

    A seed is the front of a range already carried: the oldest atom that
    request carried. It is a position in the keeper's checkpoint history --
    the trace -- and every runtime cuts its request from that one history,
    so a position measured on one names the same atom on the next. While the
    process holds a ledger for the (keeper, runtime) pair, the seed is the
    ledger's: the last request's front as every eviction since moved it.
    Without one, it is the range the newest turn record joined to an actual
    provider response, whichever runtime observed it -- an official client's
    record counts the same history as an Agent Core one -- read as
    [total_atoms - transmitted_atoms]. A front a refusal moved in this turn
    ({!Halved_after_refusal}, {!Evicted_after_refusal},
    {!Turn_start_after_seed_refusal}) belongs to the turn and takes
    precedence over an older front in a later candidate's ledger.

    A front is a position: the atom index and the digest of the message that
    opens that atom
    ({!Runtime_model_input_tail_window.atom_opening_digest}). A seed is used
    only while the history in hand opens the same index with the same
    message ({!for_history}); the history's atom count is not compared. A
    history one unsaved atom shorter keeps the position, and a checkpoint
    purge that rewrote the message opening the front drops it. *)

type source =
  | Ledger  (** The pair's ledger, moved by every eviction since its last request. *)
  | Turn_record of { turn : int }
      (** The newest turn record on the trace with a request range joined to
          an actual provider response, whichever runtime ran it. The whole
          turn may still have ended in error after that response. *)
  | Halved_after_refusal of { retry : int }
      (** A provider or wire refusal with no block ahead to evict: the range
          was halved toward the newest atom on retry [retry]. *)
  | Evicted_after_refusal of { retry : int }
      (** A provider or wire refusal moved the front past measured blocks.
          The turn shares this position with its later candidates. *)
  | Turn_start_after_seed_refusal
      (** With no Librarian point, the provider refused the range a seed
          opened as too large: the front moved to the turn boundary, and the
          turn shares that position with its later candidates and lanes. *)
  | Turn_start_after_librarian_refusal
      (** With a Librarian point, the provider refused as too large a range
          that opened before the turn boundary -- at the point, or at the
          accepted start past it: the front moved to the turn boundary for
          the rest of the turn (RFC librarian-lifecycle §4.10, rule 1). *)

type seed =
  { first_atom : int
  ; front_digest : string
        (** The opening-message digest of [first_atom] in the history the
            front was measured on. *)
  ; source : source
  }

(** Where a request with no absorbed point and no seed starts (RFC
    keeper-context-window-in-tokens §13.4), as {!Keeper_turn_driver_try_provider.turn_start}
    reads it from the keeper's turn-boundary store and checks it against
    the history in hand. *)
type turn_start =
  | Turn_boundary of { end_atom : int }
      (** The end of the last completed turn on this history, verified
          against it by digest. 0 on a history with no completed turn: the
          short history of a new keeper, all of which goes out. *)
  | Turn_boundary_unknown of { reason : string }
      (** The store could not be read, or no boundary in it matches this
          history. Where this turn began is not known, and the request opens
          on the newest atom alone ({!newest_atom}) rather than on everything:
          §13.4 does not fold an unknown start into the whole history, and a
          short range costs one turn of context where a 16 MB one costs the
          turn. [reason] is what the reader said. *)

val turn_start_to_string : turn_start -> string
(** [boundary:<end_atom>] or [unknown:<reason>], for log lines. *)

type origin =
  | Carried of source  (** The front came from a seed. *)
  | Librarian_snapshot of { end_atom : int; boundary_line : int }
  | Librarian_progress of { end_atom : int }
      (** The Librarian's durable position: the atoms before [end_atom] are
          read into memory, and nothing in the request summarizes them. Taken
          when no saved continuity snapshot fits this history and the
          position does (RFC keeper-context-window-in-tokens §13.6). *)
  | Past_librarian_point of { librarian_end_atom : int; source : source }
      (** A Librarian point at [librarian_end_atom], and a later start the
          provider accepted on this history ([source]: the newest
          response-observed turn record, or this turn's boundary after a
          size refusal). The range opens at that start (RFC
          librarian-lifecycle §4.10, rule 2). The atoms from the point up to
          it are not sent; which of them are also not in memory is
          {!librarian_gap}'s answer, which weighs the read position too. *)
  | Turn_start of { end_atom : int }
      (** No absorbed point and no seed: the range begins where the last
          completed turn on this history ended, so only this turn's own
          atoms go out and the atoms before them wait for the Librarian
          (§13.4). [end_atom] is that boundary as the turn-boundary store
          states it, not the atom the range opened on: a boundary at or past
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

val composer_of_runtime : Runtime.t option -> composer
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

type seed_read =
  { seed : seed option
  ; unreadable : unreadable_records option
        (** [None] when every record read decoded. A seed is looked for among
            the records that did, so [seed = None] with [Some _] here is
            "records unreadable", not "no record". *)
  ; boundary_error : string option
        (** A refusal from the turn-boundary store that defines the current
            history generation. Kept separate from [unreadable], whose count
            is only for TurnRecord rows. A boundary error admits no seed. *)
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
    that do not counted and the first refusal kept, rows oldest first. *)

val read_seed
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> seed_read
(** The last stored response observation in the current history generation,
    scanning newest first until a match, a different trace, or a turn at or
    before the latest [History_restarted] boundary. The boundary is expressed
    in the same [absolute_turn] coordinate as TurnRecord: it is the highest
    completed turn preceding that restart in file order, never a wall-clock
    comparison. Unobserved rows do not hide an older seed within that
    generation. Storage order also resolves direct retries that reuse a turn
    number. Unreadable rows visited before the match are counted; rows older
    than the match or generation boundary are not read. A boundary-store read
    failure returns no seed and is reported in [boundary_error]. Reads on the
    calling fiber; the turn driver calls it once per provider attempt, and
    only while the pair has no ledger. *)

(** Why {!for_history} dropped a seed. *)
type dropped_front =
  | Front_atom_missing
      (** The history has no atom at [first_atom]: it is shorter than the
          front. *)
  | Front_message_differs
      (** The atom at [first_atom] opens with another message: atoms before
          the front were removed or replaced. *)

val for_history
  :  digest_at:(int -> string option)
  -> seed
  -> (seed, dropped_front) result
(** The seed when [digest_at seed.first_atom] is [Some seed.front_digest],
    where [digest_at] is {!Runtime_model_input_tail_window.atom_opening_digest}
    over the history in hand; otherwise why not. A dropped position names no
    atom of this history, and carrying the newest atom alone from there
    would never widen again, so the caller starts over as with no seed. *)

val dropped_front_to_string : dropped_front -> string

val clamp : atom_count:int -> int -> int
(** The front as a position in a history of [atom_count] atoms: at least 0,
    at most the newest atom, so the range always carries the turn. *)

val newest_atom : atom_count:int -> int
(** The newest atom of a history of [atom_count] atoms, 0 when it has none:
    where a range opens when the turn start is unknown. *)

val halve : first_atom:int -> atom_count:int -> int option
(** The front moved halfway to the newest atom, or [None] when the range is
    already a single atom and cannot shrink. *)

val source_to_string : source -> string
val seed_to_json : seed -> Yojson.Safe.t
(** [first_atom], [front_digest] and [source]. *)
val origin_to_string : origin -> string

val origin_to_json : origin -> Yojson.Safe.t
(** One object with a [kind], one per constructor: [ledger];
    [turn_record] with [turn]; [halved_after_refusal] or
    [evicted_after_refusal] with [retry]; [turn_start_after_seed_refusal];
    [turn_start_after_librarian_refusal];
    [librarian_snapshot] with [end_atom] and [boundary_line];
    [librarian_progress] with [end_atom]; [past_librarian_point] with
    [librarian_end_atom] and [front], the {!Carried} object of its source;
    [turn_start] with [end_atom]; or
    [turn_start_unknown] with [reason]. *)

(** The atoms that are in neither the request nor memory while a request
    starts at [gap_end_atom], past everything the Librarian covers (RFC
    librarian-lifecycle §4.10, rule 3). [gap_end_atom] is excluded. *)
type librarian_gap =
  { gap_start_atom : int
  ; gap_end_atom : int
  }

val librarian_gap
  :  snapshot_cut:int option
  -> read_position:int option
  -> accepted_start:int
  -> librarian_gap option
(** The one rule for the gap. What the Librarian covers ends at the later of
    its continuity snapshot's cut and its durable read position: the atoms
    before the cut are summarized, the atoms before the read position are
    in memory. The gap runs from there to just before [accepted_start], the
    start the provider last accepted. [None] when [accepted_start] is at or
    before that end, or when neither position is known. A request that
    starts past its Librarian point therefore need not leave a gap: a
    snapshot cut S behind a read position R, with the request starting at R,
    skips only atoms the Librarian has already read.

    [snapshot_cut] is taken as covered whether or not the snapshot fits the
    current history. A snapshot that no longer fits stays in its file with
    nothing on disk marking it: the turn driver finds the mismatch only by
    comparing it with the checkpoint on each request, and then sends no
    working state. So while such a snapshot remains, with its cut past the
    read position, this counts the gap short: from the cut rather than from
    the read position. Telling the two apart needs that history comparison,
    and the alarm does not make it. *)
