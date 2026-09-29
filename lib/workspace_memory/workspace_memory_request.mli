(** One bounded, source-attributed request for changed workspace facts.
    RFC-workspace-curator-curates-changed-facts section 2.4. This module does
    not call a model or change the ledger. *)

type error =
  | Invalid_limit
  | Index_unavailable of string
  | Fact_exceeds_limit of Workspace_memory_ledger.fact_ref

val error_to_string : error -> string

type batch =
  { input : Yojson.Safe.t
  ; rendered_prompt : string
  ; selected : Workspace_memory_ledger.pending_fact list
  ; remaining : Workspace_memory_ledger.pending_fact list
  ; index_stats : Keeper_memory_search_index.batch_stats
  }

val prepare
  :  max_input_bytes:int
  -> neighbor_limit:int
  -> render:(Yojson.Safe.t -> string)
  -> ledger:Workspace_memory_ledger.t
  -> current:Workspace_memory_ledger.pending_fact list
  -> pending:Workspace_memory_ledger.pending_fact list
  -> (batch option, error) result
(** Select a nonempty prefix of [pending] whose **rendered prompt** fits
    [max_input_bytes]. Neighbors are BM25-ranked facts from other Keepers in
    [current]; one transient SQLite index serves every selected query. The
    caller chooses the byte and neighbor limits from its admitted execution
    contract. A single fact that cannot fit fails explicitly. No pending facts
    return [Ok None] without building an index or rendering a prompt. *)
