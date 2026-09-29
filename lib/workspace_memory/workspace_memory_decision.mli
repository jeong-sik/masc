(** Strict one-decision-per-changed-fact output for the Workspace Curator.
    The prompt supplies only the selected batch, and this decoder refuses any
    answer that changes a fact outside it. *)

val output_schema : Yojson.Safe.t
val decode
  :  selected:Workspace_memory_ledger.pending_fact list
  -> Yojson.Safe.t
  -> (Workspace_memory_ledger.assignment list, string) result
