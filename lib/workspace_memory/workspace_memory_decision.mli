(** Strict one-decision-per-changed-fact output for the Workspace Curator.
    The prompt supplies only the selected batch, and this decoder refuses any
    answer that changes a fact outside it. *)

val output_schema : Yojson.Safe.t
val decode
  :  batch:Workspace_memory_request.batch
  -> Yojson.Safe.t
  -> (Workspace_memory_ledger.assignment list, string) result
(** Every [fact_id] is the request-local id of one selected fact, and a
    [join_claim] or [join_conflict] value is the request-local id of a claim or
    conflict the request shows. Both are mapped back to ledger identities; an
    id the request did not show is refused. *)
