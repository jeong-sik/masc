(** Keeper_carried_front — where the next request's carried range starts
    (RFC keeper-context-window-in-tokens §10.4).

    The front is the oldest atom the request carries; everything from it to
    the newest atom goes out, and it only ever moves toward the newest atom.
    It is a position in the keeper's checkpoint history — the trace — and
    every Agent Core runtime composes its request from that one history, so
    a position measured on one runtime names the same atom on the next.
    While the process holds a ledger for the (keeper, runtime) pair, the
    front is the ledger's: the last request's front as every eviction since
    moved it. Without one, the first turn after a boot or the first on this
    runtime, the seed is the range the newest completed Agent Core turn
    record on the trace measured, whichever runtime measured it, read as
    [total_atoms - transmitted_atoms]; a lane walking to its next candidate
    starts from the range the last completed turn carried rather than from
    the whole history.
    With neither, the caller has no atom to start from and carries the whole
    history; the provider judges it, and the turn driver owns the one move a
    refusal forces before any usage has been counted, which
    {!Halved_after_refusal} names. *)

type source =
  | Ledger  (** The pair's ledger, moved by every eviction since its last request. *)
  | Turn_record of { turn : int }
      (** The newest completed Agent Core turn record on the trace that
          measured its carried atoms, whichever runtime ran it. *)
  | Halved_after_refusal of { retry : int }
      (** A provider or wire refusal before any usage: the range was halved
          toward the newest atom, [retry] times so far. *)

type seed =
  { first_atom : int
  ; atom_count : int
        (** How many atoms the history had when the front was measured. A
            history that has fewer now is not the one the position names. *)
  ; source : source
  }

type origin =
  | Carried of source  (** The front came from a seed. *)
  | Whole_history
      (** No front to start from: everything, until the first usage on the
          pair is counted or a refusal halves the range. *)

val of_ledger : Keeper_model_input_ledger.t -> seed

(** Who composes a runtime's request, which says whose atoms a window it
    recorded counts. *)
type composer =
  | Composes_from_the_history
      (** An Agent Core binding: the request is cut from the keeper's
          checkpoint history, so its window is a range of atoms of that
          history. *)
  | Hands_over_its_own_list
      (** An official client: masc hands over a list and the client
          assembles the request, so the window's counts are positions in
          that list, not in the checkpoint history. *)
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
(** The newest completed record of session [trace_id] carrying a
    [model_input_window] whose runtime {!Composes_from_the_history}, in any
    order. An errored turn's record names the runtime that was asked, not
    the lane whose request it measured, so only a record with a stop reason
    is read; a record of another session measured another history; a record
    whose runtime {!Hands_over_its_own_list} counted another list; and one
    whose runtime is {!Not_materialized} is not read, since nothing says
    which it was. *)

val read_seed
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> seed option
(** {!of_records} over the keeper's newest {!records_read} turn records,
    each record's runtime answered by {!composer_of_runtime} from the live
    catalog. Reads the record file on the calling fiber; a turn calls it
    once, and only while the pair has no ledger. *)

val for_history : atom_count:int -> seed -> seed option
(** The seed when the history still has at least the atoms it was measured
    against, [None] when the history shrank under it (a checkpoint purge):
    the position then names no atom of this history, and carrying the
    newest atom alone from there would never widen again. The caller starts
    over as with no seed. *)

val records_read : int
(** How many records {!read_seed} reads. Every completed Agent Core turn
    leaves one, so the read has to reach back only past errored turns and
    official-client turns. *)

val clamp : atom_count:int -> int -> int
(** The front as a position in a history of [atom_count] atoms: at least 0,
    at most the newest atom, so the range always carries the turn. *)

val halve : first_atom:int -> atom_count:int -> int option
(** The front moved halfway to the newest atom, or [None] when the range is
    already a single atom and cannot shrink. *)

val source_to_string : source -> string
val seed_to_json : seed -> Yojson.Safe.t
val origin_to_string : origin -> string

val origin_to_json : origin -> Yojson.Safe.t
(** One object with a [kind]: [ledger], [turn_record] with [turn],
    [halved_after_refusal] with [retry], or [whole_history]. *)
