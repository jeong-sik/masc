(** One source-attributed request for changed workspace facts.
    RFC-workspace-curator-curates-changed-facts section 2.4. This module does
    not call a model or change the ledger. *)

type error =
  | Invalid_limit
  | Render_failed of string
  | Index_unavailable of string
  | Invalid_batch of string

val error_to_string : error -> string

(** One selected fact and the other-Keeper facts ranked as its neighbors. *)
type row = { fact : Workspace_memory_ledger.pending_fact; neighbors : Workspace_memory_ledger.pending_fact list }

(** Request-local ids and the ledger identities they name. *)
type ids

type batch = private
  { rows : row list  (** selected facts, oldest first *)
  ; selected : Workspace_memory_ledger.pending_fact list  (** the facts of [rows] *)
  ; input : Yojson.Safe.t
  ; rendered_prompt : string
  ; ids : ids
  ; index_stats : Keeper_memory_search_index.batch_stats
  }
(** The model input lists every fact once in [facts] (new or neighbor, with
    its Keeper, source path and current ledger membership), each referenced
    claim once in [claims] and each referenced conflict once in [conflicts].
    [new_facts] names the selected facts and their neighbors by short
    request-local ids. Ledger hashes stay in the host snapshot. *)

val selected_ids : batch -> (string * Workspace_memory_ledger.pending_fact) list
(** The request-local id of every selected fact, oldest first. The model
    answers with these ids. *)

val claim_ids : batch -> (string * string) list
(** [(request-local id, claim_id)] for every claim the request shows. *)

val conflict_ids : batch -> (string * string) list
(** [(request-local id, conflict_id)] for every conflict the request shows. *)

val batch_to_json : batch -> Yojson.Safe.t
val batch_of_json
  : ledger:Workspace_memory_ledger.t -> Yojson.Safe.t -> (batch, error) result
(** Strict snapshot of the complete original batch, not a new retrieval or
    prompt render. Rebuilds the input and id map from the snapshot rows and
    the captured [ledger] and refuses any difference, so every membership and
    entry text the model saw is the captured ledger's. Also refuses a
    neighbor owned by its selected fact's Keeper, a repeated fact and a
    selected fact already disposed in that ledger. The caller must retain the
    original ledger and rendered-template identity with this snapshot. *)

val prepare
  :  neighbor_limit:int
  -> render:(Yojson.Safe.t -> (string, string) result)
  -> ledger:Workspace_memory_ledger.t
  -> current:Workspace_memory_ledger.pending_fact list
  -> pending:Workspace_memory_ledger.pending_fact list
  -> (batch option, error) result
(** Prepare every pending fact in the given order, with BM25-ranked facts
    from other Keepers in [current]. One transient SQLite index serves all
    queries; the complete prompt is rendered once, without estimating provider
    input capacity. [neighbor_limit] bounds retrieval results and may be zero.
    No pending facts return [Ok None] without building an index or rendering a
    prompt. *)

val narrow
  :  render:(Yojson.Safe.t -> (string, string) result)
  -> ledger:Workspace_memory_ledger.t
  -> batch
  -> (batch option, error) result
(** Call only after an actual provider input-size or classification
    output-limit refusal. Keep the oldest half of the selected rows with their
    complete neighbors, rebuilt against [ledger], the parent's captured
    ledger. The index is not queried again and nothing live is read, so one
    parent always yields the same child. [Ok None] means only one indivisible
    row remains. *)
