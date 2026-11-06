val reference : Yojson.Safe.t -> (Keeper_peer_artifact_ref.t, string) result

type fetched = { blob : Tool_output.artifact_ref; content : string }
(** The exported bytes and the blob reference built from them. *)

val fetch : config:Workspace.config -> Keeper_peer_artifact_ref.t -> (fetched, string) result
(** Read an exported artifact from the workspace blob store. The store checks
    the bytes against the sha256; the reference carries nothing else. *)

val materialize :
  base_path:string -> artifact:Keeper_peer_artifact_ref.t -> path:string ->
  fetch:(unit -> (fetched, string) result) ->
  read:(max_bytes:int -> (string, Keeper_sandbox_read_backend.read_error) result) ->
  write:(Tool_output.artifact_ref -> Keeper_tool_execution.t) -> Keeper_tool_execution.t
(** Reconcile the requested recipient path through its contained read/write
    callbacks. Exact existing bytes complete without another write. Otherwise
    invoke the authorized writer once and verify the complete recipient bytes
    before reporting completion. A writer failure with uncertain/post-effect
    disposition may be reconciled by an exact read, never by replaying it.
    Newly constructed receipts and verification failures that carry the
    writer's normalized references persist their own durable result manifest
    under [base_path] before returning. Every result built after a successful
    fetch retains the fetched blob. Existing writer results are forwarded
    unchanged. Manifest storage failure keeps the proven
    effect phase and artifact roots; it never repeats the write or reuses the
    writer's manifest for a different payload.
    Gate deferrals and pre-effect refusals remain authoritative. The callbacks
    must address the same validated recipient path; no host fallback is used. *)
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  write:(Yojson.Safe.t -> Keeper_tool_execution.t) -> args:Yojson.Safe.t -> Keeper_tool_execution.t
