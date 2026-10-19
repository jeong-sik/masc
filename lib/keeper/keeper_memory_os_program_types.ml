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
