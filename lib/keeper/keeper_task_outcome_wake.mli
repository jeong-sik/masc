(** Keeper_task_outcome_wake — tell the producer Keeper that the completion
    authority approved its submitted evidence.

    The approval twin of [Completion_authority_wakeup]. A rejection has always
    reached the producer as a typed stimulus; an approval used to end the
    loop in silence: the Board receipt is Unlisted ("approval wakes nobody")
    and the producer's current-task projection was cleared at submission, so
    the producer learned its task closed only when some later cycle noticed.
    (#25868.)

    The payload is pointer-only — the verdict record and the Board receipt
    stay the content stores — and the stimulus is committed through the same
    fail-closed durable path the delegation answer and the rejection use, so
    a failed write is reported rather than swallowed. The live wake that
    follows is a hint: it only reaches a [Running] Keeper, and its failure is
    logged, because the committed stimulus is already in the queue the Keeper
    drains on its next admitted turn. *)

type delivery =
  | Signaled of { keeper_name : string }
  | Durable_deferred of {
      keeper_name : string;
      wakeup : Keeper_registry.wakeup_outcome;
    }
  | Durable_wake_failed of { keeper_name : string; detail : string }
  | Unroutable_producer of { producer : string; task_id : string }
  | Producer_identity_lookup_failed of {
      producer : string;
      task_id : string;
      detail : string;
    }
  | Durable_queue_failed of { keeper_name : string; detail : string }

val wake_approved_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  authority:Masc_domain.completion_authority ->
  delivery
(** Commit the typed approval stimulus to the producer's durable queue and
    then attempt a live wake. Identity resolution matches
    [Completion_authority_wakeup]: a live registry entry's exact [agent_name]
    binding is authoritative; a stopped producer is resolved from persisted
    Keeper metadata; an absent or ambiguous binding is an explicit typed
    delivery failure, not a silent drop. *)
