(** One source-attributed request for changed workspace facts.
    RFC-workspace-curator-curates-changed-facts section 2.4. This module does
    not call a model or change the ledger. *)

type error =
  | Invalid_limit
  | Render_failed of string
  | Index_unavailable of string
  | Invalid_batch of string
  | Measure_failed of string
  | Exceeds_frame of { fact : Workspace_memory_ledger.fact_ref; bytes : int; frame : int }
      (** The oldest pending fact with its neighbors alone measures [bytes],
          over the receiving Add-on's declared [frame]. *)
  | Invalid_size of int

(** How many facts a new batch may hold. [Fill_frame] takes as many as the
    frame holds. [Up_to n] takes at most [n], the size an earlier provider
    answer supports (RFC-workspace-curator-curates-changed-facts 2.4,
    "다음 묶음"). *)
type size = Fill_frame | Up_to of int

val error_to_string : error -> string

(** One selected fact and the other-Keeper facts ranked as its neighbors. *)
type row = { fact : Workspace_memory_ledger.pending_fact; neighbors : Workspace_memory_ledger.pending_fact list }

(** Request-local ids and the ledger identities they name. *)
type ids

type batch = private
  { rows : row list  (** selected facts in [pending] order *)
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
(** The request-local id of every selected fact, in row order. The model
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
  -> size:size
  -> frame:int
  -> measure:(batch -> (int, string) result)
  -> (batch option, error) result
(** Prepare a prefix of [pending], at most [size], whose request fits [frame],
    the receiving Add-on's declared worker frame, as [measure] counts the
    bytes the host would send for a batch. The prefix keeps the given order
    ({!Workspace_memory_ledger.reconcile} gives its new facts oldest first).
    Each fact gets BM25-ranked facts from other Keepers in [current], bounded
    by [neighbor_limit] (which may be zero), from one transient index table
    built once for the whole preparation; each fact is ranked once.
    - [Fill_frame]: the size doubles from one fact until it does not fit, then
      bisects. Ranking stops at the first size that does not fit, so at most
      twice the chosen facts are ranked.
    - [Up_to n]: the first [n] facts are ranked and measured; only when the
      frame does not hold them is a smaller prefix searched, without ranking
      more.
    Only a measured size is returned. Bytes nearly always grow with the
    prefix but can shrink a little when renumbering shortens local ids, so a
    slightly longer prefix may also fit. Either way the work follows the
    batch, not the backlog. [index_stats] counts the build and every query.
    This is the declared protocol frame, not an estimate of provider input
    capacity. No pending facts return [Ok None] without building an index or
    rendering a prompt. *)

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
