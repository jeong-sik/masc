(** Execute one retained verifier original through its host-built authority.
    Verdict extraction, commitment and Task/Goal transitions stay on the host. *)

type error =
  | Original_not_found
  | Original_corrupt of string
  | Authority_unavailable of string
  | Grants_mismatch of string
  | Execution_pending of string
  | Execution_repair_required of string
  | Persistence_unavailable of string

val run_attempt :
  ?prepare_observer_registration:(Task.Anti_rationalization.review_result ->
    (Lane_addon_request_receipt.receipt, string) result) ->
  ?on_verdict:(Task.Anti_rationalization.review_result -> unit) ->
  ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?sw:Eio.Switch.t option ->
  store:Verifier_review_owner.store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string ->
  prepare_notes:(Task.Anti_rationalization.review_result -> string) ->
  base_path:string ->
  prepare_authority:(unit -> (Verification_authority_tools.task_review, string) result) ->
  provider_rest:(string -> Task.Anti_rationalization.provider_rest) -> unit ->
  (Verifier_review_original.t * Task.Anti_rationalization.review_result, error) result
(** Strictly load the original for its recorded destination, then compare the
    host's opaque authority with its canonical binding and subject. Refuse a
    changed workspace, producer, full schema or submitted snapshot before
    dispatch. Execute the stored prompt and images; callers supply neither
    another question nor a lookup dispatch closure. The structured output
    contract must still match the review protocol. [prepare_notes] belongs to
    the host and renders its captured evidence metadata before the judgment
    and notes are published atomically. The physical owner store must belong
    to [base_path]. [prepare_authority] is called only for a not-yet-dispatched
    original; pending native executions are observed through their pre-effect
    journal bindings without reconnecting to the producer. Neither observation
    nor restored judgments rebuild lookup authority or dispatch another model. The host's actual observer registration, when
    supplied, is published atomically with the judgment in one owner record.
    A successful result includes the exact original loaded by this worker, so
    callers need not associate the verdict with a separate owner read. *)

type 'error apply_failure =
  | Outcome_unknown of { error : 'error; detail : string }
  | Authority_refused of { error : 'error; detail : string }
(** The host preserves its actual typed domain error. [Authority_refused]
    authorizes one read-only reconciliation after an explicit authority
    refusal; it never authorizes another apply. Other errors retain uncertainty.
    [detail] is journal diagnostics, never a control discriminator. *)

type 'error commit_error =
  | Worker_error of error
  | Apply_failed of 'error
  | Commit_conflicted of {
      commit : Lane_addon_request_progress.commit;
      observed : Yojson.Safe.t;
    }
(** A conflict carries the authenticated original intent and the authoritative
    third-state observation already retained in its journal. The host owns
    domain interpretation. Cached conflicts neither observe nor apply again. *)

val commit_attempt :
  store:Verifier_review_owner.store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string ->
  change:Lane_addon_request_progress.change ->
  observe:(Lane_addon_request_progress.change -> (Yojson.Safe.t, string) result) ->
  apply:(Lane_addon_request_progress.change -> (unit, 'error apply_failure) result) ->
  (unit, 'error commit_error) result
(** Host-only domain commitment of the exact retained judgment. Observe and
    apply consume the retained intent on resume, never a newly generated one.
    A possible prior commit is confirmed by the exact expected after-state or
    retried only after observing its own original before-state. *)

module For_testing : sig
  val run_attempt :
    advance_events:(store:Verifier_review_owner.store -> Verifier_review_owner.retained ->
      Lane_addon_request_progress.event list ->
      (Verifier_review_owner.retained, Verifier_review_owner.load_error) result) ->
  ?prepare_observer_registration:(Task.Anti_rationalization.review_result ->
    (Lane_addon_request_receipt.receipt, string) result) ->
  ?on_verdict:(Task.Anti_rationalization.review_result -> unit) ->
  ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?sw:Eio.Switch.t option ->
  store:Verifier_review_owner.store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string ->
  prepare_notes:(Task.Anti_rationalization.review_result -> string) ->
  base_path:string ->
  prepare_authority:(unit -> (Verification_authority_tools.task_review, string) result) ->
  provider_rest:(string -> Task.Anti_rationalization.provider_rest) -> unit ->
  (Verifier_review_original.t * Task.Anti_rationalization.review_result, error) result
end
(** Scoped publication effect injection through the same runner; production
    always uses the original owner's canonical publisher. No global hook. *)
