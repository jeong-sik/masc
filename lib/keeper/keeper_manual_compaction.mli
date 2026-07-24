type checkpoint_commit_hint_outcome =
  | Hint_not_emitted
  | Hint_delivered of Keeper_checkpoint_ref.t
  | Hint_failed of
      { installed_ref : Keeper_checkpoint_ref.t
      ; failure : Eio.Exn.with_bt
      }

type post_install_lifecycle =
  | Completion_applied
  | Completion_rejected_failure_dispatched of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error }
  | Completion_rejected_failure_dispatch_failed of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch_error : Keeper_context_runtime.lifecycle_dispatch_error
      }

type applied_receipt =
  { installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  ; manifest : (unit, string) result
  }

type success =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; receipt : applied_receipt
  }

type committed =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  }

type operation_outcome =
  | Compacted of committed
  | No_compaction of Keeper_post_turn.no_compaction

type pre_install_lifecycle_stage =
  | Operator_request
  | Compaction_started

type failure =
  | Lifecycle_before_install of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      }
  | Lifecycle_before_install_with_failure_dispatch of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result

type admitted_operation =
  [ `Applied of success
  | `No_compaction of Keeper_post_turn.no_compaction
  | `Compaction_failed of failure
  | `Busy of Keeper_turn_admission.autonomous_block
  ]

type admitted_result =
  { operation : admitted_operation
  ; checkpoint_commit_hint : checkpoint_commit_hint_outcome
  }

val run_admitted
  :  ?exact_execution_guard:Keeper_compaction_llm_summarizer.exact_execution_guard
  -> on_checkpoint_commit_hint:(Keeper_checkpoint_ref.t -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> unit
  -> admitted_result
(** The provider call runs OUTSIDE the keeper admission: [run_admitted]
    first performs a state-free availability preflight, then splits into
    [prepare_compaction] (durable load + policy + LLM plan, no slot held and no
    active lifecycle) and one admitted lifecycle section owning request +
    start + source-CAS commit + completion/failure. The lane stays runnable
    while the LLM works; a failed final admission cannot strand
    [compaction_active], and interleaved checkpoint changes fail the exact
    source CAS. [on_checkpoint_commit_hint] receives the exact installed
    checkpoint reference only after final compaction admission has been
    released. It is a lossy same-invocation hint, not an acknowledgement,
    durable event, or restart authority. Process death may drop it. Its
    delivery result is returned separately in [checkpoint_commit_hint], so a
    callback exception cannot change [operation] from [`Applied] to failure.
    A rejected completion after the checkpoint commit dispatches an explicit
    lifecycle failure cleanup, but neither rejection can turn the installed
    checkpoint into [`Compaction_failed] or a retry. The closed
    [post_install_lifecycle] fact, exact installed reference, Store auxiliary
    evidence, and manifest append result remain in the [`Applied] receipt.
    The structured manifest is appended after admission release with
    [status=degraded] and [operator_action_required=true] for every post-install
    anomaly. Pre-install lifecycle failures use separate constructors whose
    stages cannot represent completion. *)

val failure_to_string : failure -> string
val observe_manifest : keeper_name:string -> (unit, string) result -> unit

module For_testing : sig
  val preserve_no_compaction_after_final_admission_busy
    :  Keeper_event_queue_state.no_compaction_reason
    -> bool

  val run_admitted_with_install_observer :
    ?exact_execution_guard:Keeper_compaction_llm_summarizer.exact_execution_guard ->
    on_checkpoint_installed_observer:(Keeper_checkpoint_ref.t -> unit) ->
    on_checkpoint_commit_hint:(Keeper_checkpoint_ref.t -> unit) ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    admitted_result

  val checkpoint_installation_auxiliary_to_json :
    Keeper_checkpoint_store.checkpoint_installation_auxiliary ->
    Yojson.Safe.t
end
