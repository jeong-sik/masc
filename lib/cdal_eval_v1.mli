(** Cdal_eval_v1 -- Phase 1A integration facade.

    Composes Cdal_loader + Cdal_judge into a single evaluation
    pipeline, and persists verdicts to date-split JSONL.

    @since CDAL Phase 1A *)

(** Evaluation outcome: either a verdict or a load failure with
    an Inconclusive verdict describing what went wrong. *)
type eval_outcome =
  | Verdict of Cdal_types.contract_verdict
      * Cdal_friction_projection.friction_projection option
  | Load_failure of Cdal_loader.load_error * Cdal_types.contract_verdict

(** Run the full evaluation pipeline: load bundle, judge, compute friction. *)
val evaluate :
  store:Masc_mcp_cdal_runtime.Proof_store.config ->
  Masc_mcp_cdal_runtime.Cdal_proof.t ->
  eval_outcome

(** Extract the verdict from either outcome branch. *)
val verdict_of_outcome : eval_outcome -> Cdal_types.contract_verdict

(** Extract friction projection (None for load failures). *)
val friction_of_outcome :
  eval_outcome -> Cdal_friction_projection.friction_projection option

(** Persist a verdict to date-split JSONL.
    Defaults to data/cdal_verdicts. Pass [~base_dir] for test isolation. *)
val persist : ?base_dir:string -> ?task_id:string -> Cdal_types.contract_verdict -> unit
