type causal_context =
  { turn_id : int option
  ; origin : Keeper_approval_origin.t
  ; snapshot : Yojson.Safe.t
  }
(** Exact outer-turn evidence captured before the tool call. The Gate stores
    and forwards [snapshot] without interpreting its fields. *)

type request =
  { keeper_name : string
  ; operation : string
  ; input : Yojson.Safe.t
  ; call_summary : string option
      (** The one line this call is about, stated by the producer from its
          typed input through that tool's declared summary function (a shell
          tool its command line, a file tool its path, a network tool its
          URL). The Gate does not read it: it travels to the chat row the
          queue writes when the call is deferred, so the operator sees what
          was parked and not only which tool asked. [None] when the tool
          declares no summary or its statement is blank; a summary is never
          derived here from the [input] fields. *)
  ; base_path : string
  ; causal_context : causal_context option
  ; task_id : string option
  ; continuation_channel : Keeper_continuation_channel.t option
  ; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option
      (** The typed sandbox a [tool_execute] will dispatch into, taken from
          the dispatch bundle at the call site — the route authority for the
          observation-only classification ({!Keeper_gate_readonly}). [None]
          for every non-execute operation. The sandbox labels inside [input]
          are display/audit data; no decision reads them. *)
  }

(** Gate operation vocabulary — the strings the approval store keys on and
    the host replay engine dispatches on. The Gate owns them so the
    deferred payload's promise cannot drift from what replay actually
    spends; producers borrow the literal from here instead of declaring
    their own. *)
val filesystem_write_gate_operation : string
val tool_execute_gate_operation : string
val network_read_gate_operation : string
val connector_post_gate_operation : string
val identity_call_gate_operation : string
val voice_speak_gate_operation : string

type replayable =
  | Replay_write
  | Replay_execute
  | Replay_network_read
  | Replay_connector_post
  | Replay_identity
  | Replay_voice_speak

val replayable_operation : string -> replayable option
(** Whether an approved operation is executed by the host replay engine
    ({!Keeper_gate_replay}). The deferred payload's [on_approve] wording
    follows this: a "host replays this exact call" promise made over an
    unrecognized operation starves the approved effect silently. *)

type boxed_execution =
  { run : Keeper_types_profile_sandbox.observation_run
  ; result : Masc_exec.Exec_dispatch.dispatch_result
  }
(** A request that already ran, including the exact result the caller must
    return. [Observe] reaches this state only on exit 0. [Guest_local] reaches
    it for every process status: guest writes may already have landed. *)

type authorization_source =
  | One_shot_resolution of string
  | Exact_always_rule of string
  | Keeper_always_allow
  | Workspace_always_allow
  | Readonly_sandbox
      (** The request is a closed-set observation-only argv inside a
          per-keeper disposable guest — docker container or microvm
          ({!Keeper_gate_readonly}); allowed without judgment. *)
  | Local_output
      (** The operation's effect lands only on the operator's own outputs:
          a speak ({!voice_speak_gate_operation}) plays on the operator's
          speakers and is appended to the keeper's own chat. [Auto_judge]
          allows it without a judge; Manual still parks it for the operator,
          and the per-keeper and [voice.gate] exemptions still skip the Gate
          entirely. *)
  | Observed_in_box of boxed_execution
      (** The request ran once inside the executor's box. Under
          [Observe] the guest kernel refused every file write outside a
          scratch and every socket (Landlock and seccomp, RFC-0422), so
          nothing it did could have left an effect; under [Guest_local] the
          writes it made landed inside the endpoint, and the operator chose
          to let those pass without judgment (RFC-0422 §3.4). The Keeper
          microVM route currently refuses this mode because volume ownership
          is unverified; the OpenSSH route requires [private_home]. Either way
          its output is returned and no judge is
          asked; the audit row names which box it was. A [Guest_local] failure
          is returned as a failed process result too, without whole-call
          replay: an arbitrary script may already have changed the tree. *)

(* The closed reading of the shim's refusal, the same type the approval row
   stores. The child names which of its rules could not be installed over the
   boundary pipe, so nothing is read back out of stderr here. *)
(** Why the box could not be built for the observed attempt — the closed
    reading of the shim's typed acknowledgement, and the same type the
    approval row stores. In every kind the requested program never started,
    so a refusal says nothing about what the program would have done; it
    always keeps the judge. See
    {!Keeper_approval_queue_rules_types.observed_refusal_kind} for what each
    kind means. *)
type refusal_kind = Keeper_approval_queue_rules_types.observed_refusal_kind =
  | Socket_rule_not_applied
  | Write_rule_not_applied
  | Setup_failed
  | Unattributed

(** What one run of the request inside the executor's box came back as
    (RFC-0422). The caller that owns the sandbox runs it; the Gate only
    decides when to ask, and what each answer means. Since review
    5192723206 no refusal answer allows on its own: the box's ack channel
    can only report the box failing to apply, never the payload being
    blocked after "A", so every {!Observed_refused} keeps the judge under
    every network mode until a path can observe attempts (a separate
    observation channel). *)
type observation =
  | Observed_result of boxed_execution
      (** Any payload result with an acknowledged enforced box. The result
          travels with the decision without a second dispatch. Nonzero status
          is not an effect-permission request or proof of sandbox denial. *)
  | Observed_refused of
      { status : Unix.process_status
      ; stderr : string
      ; refusal_kind : refusal_kind
      }
      (** The shim's typed receipt reports that the box could not be built,
          so the program never started. A nonzero payload exit alone cannot
          construct this outcome. Every stage the request dispatched was
          refused this way, so nothing started. Every kind keeps the judge. *)
  | Observed_partly_refused of { refusal_kind : refusal_kind }
      (** A multi-stage request (sequence, pipeline, substitution) where at
          least one stage's box applied (its program may or may not have started:
          an applied box whose exec failed counts) and at least one
          other stage's box could not be built. [refusal_kind] is the first
          refusing stage's. No observation is written to the row, because the
          row's observation says nothing started; the request keeps the
          judge. *)
  | Observation_unavailable of string
      (** No box could be built for this request — a profile with no shim, a
          shim that advertises no box, a dispatch the typed gate refused — so
          the request keeps the judge exactly as before this stage existed.
          Never read as clean. *)

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

(** Every reason above says the approval machinery could not act, not that
    the call was wrong or that the effect half-happened. Callers report
    {!Unavailable} as [Tool_result.Dependency_unavailable] with
    [Proven_pre_effect]. Four of the five call sites reported
    [Runtime_failure] until 2026-09-06, which reaches a model as
    [Agent_core.Types.Unknown] -- an uncertain outcome, next to a message
    saying the effect was not executed. *)

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
