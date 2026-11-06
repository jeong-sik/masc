val reference : Yojson.Safe.t -> (Keeper_peer_artifact_ref.t, string) result

type fetched = private { blob : Tool_output.artifact_ref; content : string }
(** The exported bytes and the blob reference built from them. Only {!fetch}
    builds one, so [blob] always describes [content]. *)

type fetch_error =
  | Absent of Keeper_peer_artifact_ref.t
      (** The store holds no blob with this sha256: nobody exported it, or the
          blob GC removed it after every ledger row naming it expired. *)
  | Unreadable of string
      (** The store could not return bytes that match the sha256. *)

val fetch_error_to_string : fetch_error -> string

val fetch_error_class : fetch_error -> Tool_result.tool_failure_class
(** An absent blob is a [Workflow_rejection]: the call names bytes the store
    does not hold, and the same call fails until that file is exported again.
    An unreadable blob is a [Runtime_failure]. *)

val fetch : config:Workspace.config -> Keeper_peer_artifact_ref.t -> (fetched, fetch_error) result
(** Read an exported artifact from the workspace blob store. The store checks
    the bytes against the sha256; the reference carries nothing else. *)

val materialize :
  base_path:string -> artifact:Keeper_peer_artifact_ref.t -> path:string ->
  fetch:(unit -> (fetched, fetch_error) result) ->
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
    fetch, and a verified writer success, retains the fetched blob. Other
    writer results are forwarded unchanged. Manifest storage failure keeps the proven
    effect phase and artifact roots; it never repeats the write or reuses the
    writer's manifest for a different payload.
    Gate deferrals and pre-effect refusals remain authoritative. The callbacks
    must address the same validated recipient path; no host fallback is used. *)
val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  write:(Yojson.Safe.t -> Keeper_tool_execution.t) -> args:Yojson.Safe.t -> Keeper_tool_execution.t
