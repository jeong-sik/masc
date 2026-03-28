(** Cdal_eval_v1 -- Phase 1A integration facade.

    Composes Cdal_loader + Cdal_judge into a single evaluation
    pipeline, and persists verdicts to date-split JSONL.

    @since CDAL Phase 1A *)

(** Evaluation outcome: either a verdict or a load failure with
    an Inconclusive verdict describing what went wrong. *)
type eval_outcome =
  | Verdict of Cdal_types.contract_verdict
  | Load_failure of Cdal_loader.load_error * Cdal_types.contract_verdict

(** Run the full evaluation pipeline: load bundle, judge, return outcome. *)
val evaluate :
  store:Agent_sdk.Proof_store.config ->
  Agent_sdk.Cdal_proof.t ->
  eval_outcome

(** Extract the verdict from either outcome branch. *)
val verdict_of_outcome : eval_outcome -> Cdal_types.contract_verdict

(** Persist a verdict to date-split JSONL under data/cdal_verdicts. *)
val persist : Cdal_types.contract_verdict -> unit

(** {2 Testing helpers} *)

(** Reset the internal JSONL store (for test isolation). *)
val reset_store_for_testing : unit -> unit

(** Override the JSONL store base directory (for test isolation). *)
val set_store_for_testing : base_dir:string -> unit
