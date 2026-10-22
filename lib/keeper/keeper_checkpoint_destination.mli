(** One dispatch's checkpoint destination. Independent operation branches must
    use their original retained source and Owner child throughout preparation,
    native callbacks, recovery and finalization. This is not a runtime setting. *)
type t
val canonical : keeper_name:string -> session_dir:string -> t
val capture_direct : base_path:string -> keeper_name:string -> session_dir:string ->
  trace_id:Keeper_id.Trace_id.t -> operation_id:Keeper_chat_operation.Operation_id.t ->
  (t, string) result
(** Read actual operation ownership. An existing branch captures its opaque
    original child writer and exact retained head; a non-branch uses canonical
    persistence. Missing or inconsistent owned evidence remains an error. *)
val destination : t -> Keeper_owner.input_checkpoint_destination
val current_checkpoint : t -> (Agent_core.Checkpoint.t option, string) result
(** Some is this dispatch's latest confirmed branch payload. Canonical returns
    None; its existing caller tracks actual Saved results. Uncertain branch
    publication remains Error rather than becoming source/retry authority. *)
val save : t -> Agent_core.Checkpoint.t ->
  (Keeper_checkpoint_store.save_agent_core_outcome, string) result
(** Canonical mode uses the existing Keeper save. Branch mode freshly confirms
    exact retention then publishes under the captured child and known branch
    predecessor. Pending ownership, scope and native settlement are rechecked.
    It never reads or writes canonical/global G. Errors and exceptions, including cancellation, fence this dispatch's
    subsequent reads and writes until original ownership is reconciled afresh.
    Exceptions retain their original backtrace. *)
val save_transformed : t -> transformation:Keeper_checkpoint_host_transform.t ->
  Agent_core.Checkpoint.t ->
  (Keeper_checkpoint_store.save_agent_core_outcome, string) result
(** Explicit replay/incomplete-response transformations use their exact witness.
    Branch publication rechecks this dispatch's known predecessor and retained
    payload; an arbitrary caller flag cannot authorize losing history. *)
val publish_native : t -> checkpoint:Agent_core.Checkpoint.t ->
  (unit -> (Keeper_checkpoint_ref.t * 'a, string) result) -> ('a, string) result
(** Fence the dispatch before actual retention/Owner/Producer publication.
    Only a confirmed publication whose branch/native references name this exact
    payload restores Confirmed. Failed or uncertain commits, cancellation and
    later observation errors never expose the prior payload as confirmed latest.
    The callback's exception propagates unchanged; no effect is retried here. *)
val path : t -> Agent_core.Checkpoint.t -> (string, string) result
(** Actual destination path for manifest evidence; never reports canonical G
    as the artifact of an operation branch save. *)
