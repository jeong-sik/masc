type causal_context =
  { turn_id : int option
  ; snapshot : Yojson.Safe.t
  }

type request =
  { keeper_name : string
  ; operation : string
  ; input : Yojson.Safe.t
  ; call_summary : string option
  ; base_path : string
  ; causal_context : causal_context option
  ; task_id : string option
  ; continuation_channel : Keeper_continuation_channel.t option
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option
  }

(* Gate operation vocabulary — the strings the approval store keys on and
   the host replay engine dispatches on. The Gate owns them so that
   [replayable_operation], which decides what the deferred payload may
   promise the model, cannot drift from the literal a producer submits:
   a deferred "the host replays this exact call" spoken over an operation
   the replay engine does not recognize starves the approved effect
   silently (2026-09-02 keeper_voice_speak incident, #32668). *)
let filesystem_write_gate_operation = "filesystem_write"

let tool_execute_gate_operation = "tool_execute"

let network_read_gate_operation = "network_read"

let connector_post_gate_operation = "connector_post"

let identity_call_gate_operation = "identity_call"

(* Not read from Keeper_tool_voice_runtime.command_to_string: that module
   sits above the Gate in the dependency graph (its chat/broadcast leaves
   reach back here through the turn driver), so borrowing the literal
   would close a cycle. The pairing with command_to_string Speak is pinned
   by test_speak_replays_while_listen_never_reaches_the_gate. *)
let voice_speak_gate_operation = "keeper_voice_speak"

type replayable =
  | Replay_write
  | Replay_execute
  | Replay_network_read
  | Replay_connector_post
  | Replay_identity
  | Replay_voice_speak

let replayable_operation operation =
  if String.equal operation filesystem_write_gate_operation
  then Some Replay_write
  else if String.equal operation tool_execute_gate_operation
  then Some Replay_execute
  else if String.equal operation network_read_gate_operation
  then Some Replay_network_read
  else if String.equal operation connector_post_gate_operation
  then Some Replay_connector_post
  else if String.equal operation identity_call_gate_operation
  then Some Replay_identity
  else if String.equal operation voice_speak_gate_operation
  then Some Replay_voice_speak
  else None
;;

type boxed_execution =
  { run : Keeper_types_profile_sandbox.observation_run
  ; result : Masc_exec.Exec_dispatch.dispatch_result
  }

type authorization_source =
  | One_shot_resolution of string
  | Exact_always_rule of string
  | Keeper_always_allow
  | Workspace_always_allow
  | Readonly_sandbox
  | Local_output
  | Observed_in_box of boxed_execution

(* The closed reading of the shim's refusal, the same type the approval row
   stores. The child names which of its rules could not be installed over the
   boundary pipe, so nothing is read back out of stderr here. *)
type refusal_kind = Keeper_approval_queue_rules_types.observed_refusal_kind =
  | Socket_rule_not_applied
  | Write_rule_not_applied
  | Setup_failed
  | Unattributed

type observation =
  | Observed_result of boxed_execution
  | Observed_refused of
      { status : Unix.process_status
      ; stderr : string
      ; refusal_kind : refusal_kind
      }
  | Observed_partly_refused of { refusal_kind : refusal_kind }
  | Observation_unavailable of string

type authorization =
  { source : authorization_source
  ; audit_receipts : Keeper_approval.Audit.receipt list
  }

type deferred_reason =
  | Human_requested
  | Judge_requested
  | Auto_judge_unavailable of string
  | Mode_state_invalid of string

type unavailable_reason =
  | Queue_storage_unavailable of Keeper_approval_queue_result.storage_error
  | Approval_grant_unavailable of Keeper_approval_queue_result.grant_error
  | Approval_grant_consumption_in_progress of string

type decision =
  | Allow of authorization
  | Deferred of
      { operation : string
      ; approval_id : string
      ; reason : deferred_reason
      ; audit_receipts : Keeper_approval.Audit.receipt list
      }
  | Unavailable of unavailable_reason

type auto_judge_completion_rejection =
  | Completion_not_found
  | Completion_key_mismatch
  | Completion_invalid_identity
  | Completion_summary_not_pending
  | Completion_unbound_state
  | Completion_disposition_conflict
  | Completion_identity_conflict
  | Completion_status_conflict
  | Completion_provenance_mismatch
  | Completion_content_conflict

type auto_judge_resume_failure_code =
  | Resume_worker_start_failed
  | Resume_identity_unbound
  | Resume_completion_persistence_uncertain
  | Resume_completion_rejected of auto_judge_completion_rejection
  | Resume_judgment_resolution_failed
  | Resume_exact_state_not_completed

type auto_judge_resume_failure =
  { approval_id : string
  ; code : auto_judge_resume_failure_code
  ; operator_detail : string
  }

type auto_judge_resume_report =
  { requested : int
  ; started_ids : string list
  ; finalized_ids : string list
  ; skipped_ids : string list
  ; failures : auto_judge_resume_failure list
  ; queue_error : Keeper_approval_queue_result.storage_error option
  }
