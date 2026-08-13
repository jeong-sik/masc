(** Closed identity contract for one capability-proof matrix cell.

    This module contains no runtime discovery or execution effects. Callers
    resolve those facts first, then create an immutable case identity here. *)

type exact_lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction

type proof_role =
  | Autonomous_keeper
  | Completion_authority
  | Verification
  | Cross_verifier
  | Exact_lane of exact_lane
  | Fusion_panel
  | Fusion_judge
  | Fusion_meta_judge

type capability_case =
  | Provider_probe
  | Autonomous_turn
  | Verification_run
  | Cross_verification
  | Librarian_run
  | Hitl_auto_judge_run
  | Board_attention_run
  | Compaction_run
  | Fusion_panel_run
  | Fusion_judge_run
  | Fusion_meta_judge_run
  | Queue_fifo
  | Scheduler_occurrence
  | Board_comment
  | Task_lifecycle
  | Goal_lifecycle
  | Tool_serial
  | Tool_parallel
  | Tool_batch
  | Async_lifecycle
  | Sandbox_containment
  | Broadcast_turn
  | Stream_replay
  | Restart_succession

type scenario =
  | Nominal
  | Invalid_input
  | Provider_rejected
  | Effect_denied
  | Effect_deferred
  | Cancelled
  | Restart_recovery
  | Outcome_unknown
  | Duplicate_delivery
  | Blocked_head

type protocol =
  | Agent_core_http
  | Official_client
  | Mcp
  | Dashboard_http
  | Sse
  | Websocket
  | Browser
  | Durable_store
  | Domain_api

type field =
  | Runtime_id
  | Model_id
  | Build_commit
  | Config_revision

type create_error = Blank_field of field

type t
type case_id = private string

val create
  :  runtime_id:string
  -> model_id:string option
  -> role:proof_role
  -> capability:capability_case
  -> scenario:scenario
  -> protocol:protocol
  -> build_commit:string option
  -> config_revision:string option
  -> (t, create_error) result
(** Rejects blank present values. Exact absence remains [None] and is encoded
    distinctly; the constructor never fabricates an unknown model, build, or
    configuration revision. *)

val case_id : t -> case_id
val case_id_to_string : case_id -> string

val runtime_id : t -> string
val model_id : t -> string option
val role : t -> proof_role
val capability : t -> capability_case
val scenario : t -> scenario
val protocol : t -> protocol
val build_commit : t -> string option
val config_revision : t -> string option

val protocol_to_string : protocol -> string
val create_error_to_string : create_error -> string

val all_proof_roles : proof_role list
val all_capability_cases : capability_case list
val all_scenarios : scenario list
val all_protocols : protocol list
(** Closed variant inventories used by manifest generators. *)

type proof_path =
  | Hermetic
  | Isolated
  | Fleet

type evidence_kind =
  | Journal
  | Receipt
  | Durable_queue
  | Gate
  | Domain_store
  | Api
  | Sse_trace
  | Browser_screenshot
  | Config_snapshot
  | Deployment_identity

type evidence_ref

type evidence_error =
  | Blank_locator
  | Blank_captured_at
  | Invalid_sha256

val create_evidence_ref
  :  path:proof_path
  -> kind:evidence_kind
  -> locator:string
  -> sha256:string
  -> captured_at:string
  -> (evidence_ref, evidence_error) result

val evidence_error_to_string : evidence_error -> string

type evidence_bundle

type bundle_error =
  | Missing_proof_paths of proof_path list
  | Duplicate_evidence_ref of string

val evidence_bundle_refs : evidence_bundle -> evidence_ref list

type failure_kind =
  | Contract_violation
  | Provider_failure
  | Infrastructure_failure
  | Evidence_mismatch
  | Stream_replay_duplicate
  | Queue_order_violation
  | Sandbox_escape
  | Scheduler_settlement_failure
  | Gate_settlement_failure
  | Domain_receipt_failure

type unsupported_reason =
  | Runtime_role_not_declared of proof_role
  | Protocol_not_supported of protocol
  | Capability_not_declared of capability_case

type blocker_ref = private string

type proof_result = private
  | Passed of evidence_bundle
  | Failed of failure_kind * evidence_ref list
  | Unsupported of unsupported_reason
  | Not_run
  | Blocked of blocker_ref

type result_error =
  | Invalid_evidence_bundle of bundle_error
  | Failure_without_evidence
  | Blank_blocker_ref

val passed : evidence_ref list -> (proof_result, result_error) result
val failed : failure_kind -> evidence_ref list -> (proof_result, result_error) result
val unsupported : unsupported_reason -> proof_result
val not_run : proof_result
val blocked : string -> (proof_result, result_error) result

val failure_kind_to_string : failure_kind -> string
val proof_result_to_string : proof_result -> string
val result_error_to_string : result_error -> string
