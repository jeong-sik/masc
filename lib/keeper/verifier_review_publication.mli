(** Task host publication over the original owner's existing observer journal.
    Execution facts are captured from the actual live review before its domain
    commit. Recovery never invents original clocks or tool observations. *)
val authority : Masc_domain.completion_authority
(** The one typed system completion authority consumed by the lane and its
    observation validators. *)

val terminal_authority_of_conflict :
  task_id:string -> Yojson.Safe.t -> (string, string) result

val execution_receipt :
  original:Verifier_review_original.t -> result:Task.Anti_rationalization.review_result ->
  before:Masc_domain.task_status -> expected:Verification_run_registry.run -> (Lane_addon_request_receipt.receipt, string) result
(** Build the opaque actual execution observation before the worker publishes
    judgment+Registration intent in the same physical owner transaction. The
    evaluated row is precommit evidence, not a claim of domain completion. *)

val captured_before : Verifier_review_owner.retained -> (Masc_domain.task_status, string) result
(** The immutable actual Awaiting snapshot, never a later terminal Task or a
    reconstructed lifecycle clock. *)

val needs_publication : Verifier_review_owner.retained -> (bool, string) result
(** Finished/Conflicted facts remain pending until their exact terminal payload
    has a validated Completion ACK. A pruned registry row does not reactivate it. *)

val publish_terminal :
  store:Verifier_review_owner.store -> registry:Verification_run_registry.t ->
  retained:Verifier_review_owner.retained ->
  outcome:Verification_run_registry.outcome -> (unit, string) result
(** Retain Completion intent, confirm its full immutable row in the canonical
    registry transaction, then ACK Registration and Completion. *)

val recover_terminal :
  store:Verifier_review_owner.store -> registry:Verification_run_registry.t ->
  retained:Verifier_review_owner.retained ->
  (Verification_run_registry.outcome, string) result
(** Publish only the authenticated historical terminal fact. No Task lookup,
    preparation, model execution or domain effect is performed. *)
