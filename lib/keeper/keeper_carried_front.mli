(** Keeper_carried_front — where the next request's carried range starts
    (RFC keeper-context-window-in-tokens §10.4).

    The front is the oldest atom the request carries; everything from it to
    the newest atom goes out, and it only ever moves toward the newest atom.
    While the process holds a ledger for the (keeper, runtime) pair, the
    front is the ledger's: the last request's front as every eviction since
    moved it. Without one, the first turn after a boot or the first on this
    runtime, the seed is the range the newest completed turn record on the
    runtime measured, read as [total_atoms - transmitted_atoms]. With
    neither, the caller has no atom to start from and fits the request-body
    cap or carries the whole history; the turn driver owns that choice, and
    it owns the one move a refusal forces before any usage has been counted,
    which {!Halved_after_refusal} names. *)

type source =
  | Ledger  (** The pair's ledger, moved by every eviction since its last request. *)
  | Turn_record of { turn : int }
      (** The newest completed turn record on the runtime that measured its
          carried atoms. *)
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
  | Fit_to_request_cap
      (** No front to start from: the newest suffix the request-body cap
          admits, until the first usage on the pair is counted. *)
  | Whole_history  (** No front and no cap: everything, until then. *)

val of_ledger : Keeper_model_input_ledger.t -> seed

val of_records : runtime_id:string -> trace_id:string -> Turn_record.t list -> seed option
(** The newest completed record of session [trace_id] on [runtime_id]
    carrying a [model_input_window], in any order. An errored turn's record
    names the runtime that was asked, not the lane whose request it
    measured, so only a record with a stop reason is read; a record of
    another session measured another history. *)

val read_seed
  :  config:Workspace.config
  -> keeper_name:string
  -> runtime_id:string
  -> trace_id:string
  -> seed option
(** {!of_records} over the keeper's newest {!records_read} turn records.
    Reads the record file on the calling fiber; a turn calls it once, and
    only while the pair has no ledger. *)

val for_history : atom_count:int -> seed -> seed option
(** The seed when the history still has at least the atoms it was measured
    against, [None] when the history shrank under it (a checkpoint purge):
    the position then names no atom of this history, and carrying the
    newest atom alone from there would never widen again. The caller starts
    over as with no seed. *)

val records_read : int
(** How many records {!read_seed} reads. A keeper that walks three or four
    lanes leaves most records on the others, so the read reaches back far
    enough to meet one on this runtime. *)

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
    [halved_after_refusal] with [retry], [fit_to_request_cap], or
    [whole_history]. *)
