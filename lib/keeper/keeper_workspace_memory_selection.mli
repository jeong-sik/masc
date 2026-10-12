(** Purpose-specific shared-memory selection. This component never mutates
    memory, equates event lineages, or treats model selection as truth proof.
    The request adapter must supply the frozen purpose and ledger identity. *)
type candidate = { id : string; summary : string }

type use = For_current_decision | For_comparison

type evaluation_error = Capacity_refused of string | Unavailable of string

type deferred =
  | Evaluation_failed of string
  | Capacity_unresolved of string
  | Invalid_answer of string
  | Source_unavailable of string
  | Applicability_unresolved

type outcome =
  | Selected of { candidate : candidate; use : use; source_detail : Yojson.Safe.t }
  | Not_needed of candidate
  | Deferred of { candidate : candidate; reason : deferred }

(** The adapter persists the exact request before dispatch and retains the
    terminal response. A failed evaluation is not a negative relevance vote.
    Cancellation must propagate. *)
type evaluate =
  state:Yojson.Safe.t -> questions:(string * Typesafeai_types.question) list ->
  (Typesafeai_types.eval_response, evaluation_error) result

val select :
  evaluate:evaluate ->
  resolve:(id:string -> (Yojson.Safe.t, string) result) ->
  purpose:Yojson.Safe.t -> candidate -> outcome
(** First assess the candidate summary. Unless it is not needed, resolve its
    authoritative member sources and reassess with that detail. Deliver only
    after the second assessment establishes a use. A second request for source
    detail remains unresolved; it neither spins nor silently drops the candidate.
    [resolve] must reject a changed ledger identity and preserve source gaps.

    Different incidents/environments can be useful comparison material.
    [For_comparison] never authorizes applying their state to the current event.
    The caller preserves [Deferred] entries separately from [Not_needed]. *)

val select_many :
  evaluate:evaluate ->
  resolve:(id:string -> (Yojson.Safe.t, string) result) ->
  purpose:Yojson.Safe.t -> candidate list -> outcome list
(** Batch summaries, then batch the successfully resolved source details.
    Results preserve input order. Missing answers remain deferred per candidate;
    duplicate or unknown answer IDs invalidate that assessment batch. Empty
    batches never dispatch. Candidate IDs are stable question IDs across stages;
    duplicate candidate IDs are rejected before dispatch. Explicit capacity refusals
    split the rejected batch into smaller batches with unchanged purpose and rows.
    A refused singleton stays deferred intact. Other failures never trigger splitting. *)

val select_resolved_many :
  evaluate:evaluate -> purpose:Yojson.Safe.t ->
  (candidate * Yojson.Safe.t) list -> outcome list
(** Assess already-resolved authoritative sources on the first request, without
    a summary-only omission before lineage is visible. Outcomes preserve input
    order and selected entries retain their exact supplied detail. A request for
    further source inspection stays [Deferred Applicability_unresolved].
    Uses the same batch identity, partial-answer and capacity-refusal contracts
    as [select_many]. The caller owns frozen source authority and revalidation
    before publication; this function does not establish freshness or truth. *)
