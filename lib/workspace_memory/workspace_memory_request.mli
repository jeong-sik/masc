(** One source-attributed request for changed workspace facts.
    RFC-workspace-curator-curates-changed-facts section 2.4. This module does
    not call a model or change the ledger. *)

type error =
  | Invalid_limit
  | Render_failed of string
  | Index_unavailable of string
  | Invalid_batch of string

val error_to_string : error -> string

type batch =
  { input : Yojson.Safe.t
  ; rendered_prompt : string
  ; selected : Workspace_memory_ledger.pending_fact list
  ; remaining : Workspace_memory_ledger.pending_fact list
  ; index_stats : Keeper_memory_search_index.batch_stats
  }

val fact_id : Workspace_memory_ledger.fact_ref -> string
(** Stable id for one fact identity, including source-bound path. The model
    returns this instead of copying the full fact reference into each answer. *)

val prepare
  :  neighbor_limit:int
  -> render:(Yojson.Safe.t -> (string, string) result)
  -> ledger:Workspace_memory_ledger.t
  -> current:Workspace_memory_ledger.pending_fact list
  -> pending:Workspace_memory_ledger.pending_fact list
  -> (batch option, error) result
(** Prepare every pending fact, with BM25-ranked facts from other Keepers in
    [current]. One transient SQLite index serves all queries; the complete
    prompt is rendered once, without estimating provider input capacity.
    [neighbor_limit] bounds retrieval results and may be zero. No pending facts
    return [Ok None] without building an index or rendering a prompt. *)

val narrow
  : render:(Yojson.Safe.t -> (string, string) result)
  -> batch
  -> (batch option, error) result
(** Call only after an actual provider input-size refusal. Retain half the
    selected whole rows, including their complete neighbors and related ledger
    entries, and prepend the other selected facts to [remaining]. The index is
    not queried again. [Ok None] means only one indivisible row remains.
    Inconsistent public batches (input rows versus selected fact identities)
    return [Invalid_batch]; no row is guessed, truncated, or silently dropped. *)
