(** Keeper_carried_front — where the next request's carried range starts
    (RFC keeper-context-window-in-tokens §10.4).

    The front is the oldest atom the request carries; everything from it to
    the newest atom goes out, and it only ever moves toward the newest atom.
    It is a position in the keeper's checkpoint history — the trace — and
    every runtime cuts its request from that one history, so a position
    measured on one names the same atom on the next.
    While the process holds a ledger for the (keeper, runtime) pair, the
    front is the ledger's: the last request's front as every eviction since
    moved it. Without one, the first turn after a boot or the first on this
    runtime, the seed is the range the newest completed turn record on the
    trace measured, whichever runtime measured it — an official client's
    record counts the same history as an Agent Core one — read as
    [total_atoms - transmitted_atoms]; a lane walking to its next candidate
    starts from the range the last completed turn carried rather than from
    the whole history.
    With neither, the range an unfinished turn on the same trace reached
    ({!Unfinished_turn}); with none of the three the caller has no atom to
    start from and carries the whole history; the provider judges it, and the turn driver owns the one move a
    refusal forces before any usage has been counted, which
    {!Halved_after_refusal} names.

    A front is a position: the atom index and the digest of the message that
    opens that atom
    ({!Runtime_model_input_tail_window.atom_opening_digest}). A seed is used
    only while the history in hand opens the same index with the same
    message ({!for_history}); the history's atom count is not compared. A
    history one unsaved atom shorter keeps the position, and a purge before
    the front moves another message under the index and drops it. *)

type source =
  | Ledger  (** The pair's ledger, moved by every eviction since its last request. *)
  | Turn_record of { turn : int }
      (** The newest completed turn record on the trace that measured its
          carried atoms, whichever runtime ran it. *)
  | Unfinished_turn of { turn : int }
      (** The newest turn record on the trace that wrote no stop
          reason: the narrowest range that turn tried, since every candidate
          of a turn shares the front a refusal moves. The record says the
          turn ended before a stop reason was written
          ({!Turn_record.finish_reason}) and never why, so this names a
          position and claims no cause. The composition starts there, at the
          position the turn reached, and moves no further on its own — a turn
          ends for reasons that say nothing about size, and those repeat
          ({!Keeper_turn_driver_try_provider.compose_carried_model_input}).
          Without this record a keeper whose seeds are gone repeats the whole
          history every turn: the halving a refusal forces lives only inside
          the turn, and the record that carries it forward was skipped for
          having no finish reason (2026-09-18: five keepers). *)
  | Halved_after_refusal of { retry : int }
      (** A provider or wire refusal before any usage: the range was halved
          toward the newest atom, [retry] times so far. *)

type seed =
  { first_atom : int
  ; front_digest : string
        (** The opening-message digest of [first_atom] in the history the
            front was measured on. *)
  ; source : source
  }

type origin =
  | Carried of source  (** The front came from a seed. *)
  | Whole_history
      (** No front to start from: everything, until the first usage on the
          pair is counted or a refusal halves the range. *)

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
    of [None]. The one reader of this question: the seed and the forecast's
    lane check both put it. *)

val composer_to_string : composer -> string

val of_records
  :  composer:(string -> composer)
  -> trace_id:string
  -> Turn_record.t list
  -> seed option
(** The newest record of session [trace_id] carrying a [model_input_window]
    whose runtime the catalog materializes, in any order, tagged
    {!Turn_record} when the turn recorded a stop reason and
    {!Unfinished_turn} when it did not. Both name a range of the same
    history, and so does an official client's record
    ({!Hands_over_its_own_list}). A record of another session measured
    another history, and one whose runtime is {!Not_materialized} is not
    read, since nothing says which list it counted. *)

type unreadable_records =
  { count : int  (** At least 1. *)
  ; first_reason : string
        (** The decoder's error for the oldest row that did not decode. *)
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
  }

val no_seed_read : seed_read
(** No seed and nothing unreadable: a caller that reads no records. *)

val seed_read_of_rows
  :  composer:(string -> composer)
  -> trace_id:string
  -> Yojson.Safe.t list
  -> seed_read
(** {!of_records} over the rows that decode as turn records, with the rows
    that do not counted and the first refusal kept, rows oldest first. *)

val read_seed
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> seed_read
(** {!seed_read_of_rows} over the JSON rows of the keeper's newest
    {!records_read} turn records, each record's runtime answered by
    {!composer_of_runtime} from the live catalog. Reads the record file on the
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

val records_read : int
(** How many records {!read_seed} reads. Every completed turn leaves one,
    whichever runtime ran it, so the read has to reach back only past turns
    whose runtime the catalog no longer has. *)

val clamp : atom_count:int -> int -> int
(** The front as a position in a history of [atom_count] atoms: at least 0,
    at most the newest atom, so the range always carries the turn. *)

val halve : first_atom:int -> atom_count:int -> int option
(** The front moved halfway to the newest atom, or [None] when the range is
    already a single atom and cannot shrink. *)

val source_to_string : source -> string
val seed_to_json : seed -> Yojson.Safe.t
(** [first_atom], [front_digest] and [source]. *)
val origin_to_string : origin -> string

val origin_to_json : origin -> Yojson.Safe.t
(** One object with a [kind]: [ledger], [turn_record] with [turn],
    [unfinished_turn] with [turn], [halved_after_refusal] with [retry], or
    [whole_history]. *)
