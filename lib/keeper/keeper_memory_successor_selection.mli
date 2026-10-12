(** Query-time semantic selection of committed successors. Historical text is
    lookup provenance, never a current claim. No store lock spans evaluation. *)
type decision = Applies_to_query | Different_scope | Uncertain

type issue =
  | Route_unavailable of Typesafeai_config.unavailable_reason
  | Evaluation_failed of Keeper_workspace_memory_selection.evaluation_error
  | Invalid_answer of string
  | Judgment_uncertain
  | Evidence_changed
  | Evidence_read_failed of string
  | Evidence_persistence_failed of string

type selection =
  { selected : Keeper_memory_os_current.successor_recall_candidate list
  ; unresolved : (Keeper_memory_os_current.successor_recall_candidate * issue) list
  }

val issue_to_json : issue -> Yojson.Safe.t
val candidate_to_json : Keeper_memory_os_current.successor_recall_candidate -> Yojson.Safe.t
val select_with_evaluate :
  evaluate:(state:Yojson.Safe.t -> questions:(string * Typesafeai_types.question) list ->
    (Typesafeai_types.eval_response, Keeper_workspace_memory_selection.evaluation_error) result) ->
  query:string -> Keeper_memory_os_current.successor_recall_candidate list -> selection
(** Deterministic orchestration with an injected effect. One meaningful pair per
    request. An individual refusal does not discard other selected pairs. *)
val revalidate : snapshot:Keeper_memory_os_current.t option ->
  candidates:Keeper_memory_os_current.successor_recall_candidate list ->
  current:Keeper_memory_os_current.successor_recall -> selection -> selection
(** Revalidate all assessed witnesses, including negative decisions. A changed
    snapshot or witness becomes unresolved exactly once. No I/O is performed. *)
val run : clock:[> float Eio.Time.clock_ty ] Eio.Resource.t option ->
  config:Workspace.config -> keepers_dir:string -> keeper_id:string ->
  query:string -> snapshot:Keeper_memory_os_current.t option ->
  Keeper_memory_os_current.successor_recall_candidate list -> selection
(** [clock] bounds each judgment request with the HTTP client's request
    timeout. Without one, an endpoint that accepts the request and never
    answers holds the caller with no time limit. *)
