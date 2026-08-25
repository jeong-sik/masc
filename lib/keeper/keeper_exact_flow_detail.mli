(** Rendering of AGENT_CORE exact-output flow errors with their per-slot provenance.

    Every masc consumer of [Agent_core.Exact_output] flow errors (HITL summary
    worker, librarian runtime) renders through this module, so an error's
    candidate identity, typed cause, raw provider body and flow journey are
    printed once, the same way, instead of being collapsed to a static label
    at each consumer boundary. *)

(** Attempts and advances recorded in the flow evidence, one clause per
    candidate visit ("slot=... call_id=..."; "advance=a->b kind=..."). *)
val flow_evidence_detail : Agent_core.Exact_output.flow_evidence -> string

(** "slot=<id> <disposition>" for one rejected candidate. *)
val candidate_rejection_detail
  :  Agent_core.Exact_output.candidate_rejection_receipt
  -> string

(** Typed execution failure cause ("completion failed",
    "serialized request refused (http_status=...)", ...). *)
val execution_cause_detail
  :  Agent_core.Exact_output.execution_error_cause
  -> string

(** Single-line bounded excerpt of the provider's raw response body. Bodies
    longer than the excerpt bound are cut and annotated with total byte count
    and the body's sha256 so the full payload stays identifiable. *)
val raw_response_excerpt
  :  Agent_core.Exact_output.raw_response option
  -> string

(** Full rendering for [Flow_exact_execution_failed]: failing slot, execution
    error detail and the flow journey. *)
val execution_failure_detail
  :  candidate:Agent_core.Exact_output.flow_attempt_receipt
  -> cause:Agent_core.Exact_output.execution_error
  -> evidence:Agent_core.Exact_output.flow_evidence
  -> string

(** Full rendering for [Flow_candidates_exhausted]: last rejection and the
    flow journey. *)
val candidates_exhausted_detail
  :  rejection:Agent_core.Exact_output.candidate_rejection_receipt
  -> evidence:Agent_core.Exact_output.flow_evidence
  -> string
