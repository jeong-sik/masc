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
