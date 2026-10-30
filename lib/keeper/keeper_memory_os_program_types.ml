(** Immutable program data shared by the journal and pure program calculus.
    These records are data, not publication authority. The program codec and
    locked replay validate them before storage. Keeping this leaf independent
    of Current/support calculation avoids a journal/calculus module cycle. *)
open Keeper_memory_os_types

type decision =
  { run_id : string
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; input_current : fact list option
  ; sources : Keeper_librarian_unread.source list
  ; input_evidence : Yojson.Safe.t
  ; gate_evidence : Yojson.Safe.t
  ; working_state : string
  ; new_claims : fact list
  ; dropped : dropped_statement list
  ; absorbed : absorbed_statement list
  ; revisions : revision list
  }

type invalidation = {fact : fact; missing_premise_ids : string list}

type stage =
  { index : int
  ; decision : decision
  ; before : fact list
  ; after : fact list
  ; invalidated : invalidation list
  ; absorbed_applied : absorbed_statement list
  ; revisions_applied : revision list
  ; claims_refused : fact list
  }

type t =
  { transaction_id : string
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; sources : Keeper_librarian_unread.source list
  ; unread : Keeper_librarian_unread.t list
  ; initial_current : fact list option
  ; stages : stage list
  ; final_facts : fact list
  }

type execution =
  { program : t
  ; initial_facts : fact list
  ; stages : stage list
  ; final_facts : fact list
  }

(** Identity of the original Memory observation and its durable history prefix.
    A prefix includes complete journal rows, not a wall-clock freshness bound. *)
type store_anchor =
  { epoch : string
  ; snapshot : (int * string) option
  ; journal_length : int
  ; journal_sha256 : string
  }

type source_boundary =
  | Atom_boundary of
      { receipt_scope : string
      ; trace_id : string
      ; history_start_boundary_line : int
      ; start_atom : int
      ; end_atom : int
      ; last_atom_digest : string
      ; end_boundary_line : int
      ; boundary_lines_seen : int
      ; checkpoint_sha256 : string
      }
  | Official_boundary of
      { receipt_scope : string
      ; after_boundary_line : int
      ; turns : (int * Ids.Turn_ref.t * string) list
      }

type publication =
  { execution : execution
  ; captured : store_anchor
  ; locked_prior : store_anchor
  ; boundary : source_boundary
  }
(** The captured inference basis and actual locked prior remain distinct.
    The outer WAL binds this canonical proof to one target revision/hash. *)
