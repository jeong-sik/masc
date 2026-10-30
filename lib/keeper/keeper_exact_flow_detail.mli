(** masc's raw-body rendering for AGENT_CORE exact-output flow errors.

    [Agent_core.Exact_output.flow_execution_error_to_string] renders every
    terminal flow error; masc callers (Board attention, librarian runtime,
    HITL summary worker, workspace memory curator) pass [raw_response_excerpt]
    as its [raw_response_to_string] so the operator line shows a redacted
    excerpt of the provider body instead of only its sha256. *)

(** ["raw_response=<redacted excerpt>"] for one provider body, or
    ["raw_response=none"]. Bodies longer than the excerpt bound are cut on a
    UTF-8 boundary and annotated with total byte count and the body's sha256
    so the full payload stays identifiable. *)
val raw_response_excerpt
  :  Agent_core.Exact_output.raw_response option
  -> string
