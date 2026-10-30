(** Actual descriptor-backed isolated job producer. Launch/start intent is
    durable before effects; status reconciles the exact saved backend handle.
    With complete original invocation identity, repeated starts reconcile the
    already-bound job instead of preparing or launching a replacement.
    Published output references retain their typed artifacts and a durable
    manifest, with the job result available under the existing inline ceiling. *)
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  owned_job_replay:Keeper_owned_job_invocation.replay option ->
  source_context:Keeper_tool_call_log_context.turn_context option ->
  continuation_channel:Keeper_continuation_channel.t option ->
  tool_use_id:string option -> turn_ref:Ids.Turn_ref.t option -> trace_id:string option ->
  name:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t

val reconcile : Keeper_owned_job_store.record ->
  (Keeper_owned_job_store.record, Keeper_owned_job_store.error) result
(** Uses only the original frozen backend and durable intents. A completion
    recovery pulse has no authority to prepare a replacement or replay launch. *)

type held_absent
(** Process-local evidence returned only by a full recovery that held the
    exact original record with [Backend_absent]. Not execution authority. *)

val reconcile_for_recovery :
  ?presence_round:Keeper_owned_job_backend.presence_round ->
  ?previous:held_absent -> Keeper_owned_job_store.record ->
  (Keeper_owned_job_store.record * held_absent option, Keeper_owned_job_store.error) result
(** Reuse the held observation only when the entire freshly recovered owner
    record is unchanged. A missing-container hint leaves that record held;
    a positive hint or changed record requires full canonical reconciliation.
    Hint failures clear reusable evidence. Fresh supervisors and manual status
    reads retain full inspection. [presence_round] shares only the read hint,
    after that exact owner equality check. No timer, retry limit or relaunch is
    added. *)

val cleanup : Keeper_owned_job_store.record ->
  (Keeper_owned_job_store.record, Keeper_owned_job_store.error) result
(** Continue the original acknowledged terminal owner's resource cleanup.
    Commit each intent before its effect, retain uncertainty for the next
    maintenance pulse and preserve source/result/journal/GC authority. Never
    create/start a program or remove a running/replacement container. *)
