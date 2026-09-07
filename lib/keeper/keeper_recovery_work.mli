(** Durable source-bound recovery work. No worker, scheduling diversion or
    projection application is installed by this storage boundary. *)

type t
type owner
type projection

type failure =
  | Worker_failed of string
  | Source_access_unavailable of string
  | Proposal_invalid of string
[@@deriving yojson]

type status =
  | Pending
  | Running of owner
  | Proposal_recorded of projection
  | Failed of failure
  | Cancelled of string

(** A recorded proposal has only passed storage/source/claimed-identity-set validation.
    The payload is explicitly opaque and semantically unvalidated. It is not a
    provider-fit proof, a faithful-summary proof, or an applied
    Keeper checkpoint. *)
type error =
  | Invalid_input of string
  | Invalid_record of string
  | Not_found
  | Identity_conflict
  | Stale_revision
  | Stale_owner
  | Source_changed
  | Terminal_state
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Artifact_read_failed of Tool_blob_store.fetch_error
  | Artifact_missing of string
  | Artifact_write_failed of string
  | Directory_prepare_failed of string
  | Lock_failed of File_lock_eio.durable_lock_error
  | Write_failed of Keeper_fs.durable_write_error

val error_to_string : error -> string

type 'a mutation =
  { value : 'a
  ; lock_release_error : File_lock_eio.durable_lock_error option
  }
(** A successful durable transaction remains successful if lock release
    subsequently fails. The auxiliary error must remain observable.
    [Write_failed] preserves [renamed] and the failed fsync stage: after a
    possible rename, reload the ledger and reconcile the exact revision before
    retrying. Cancellation can likewise arrive after publication; neither an
    exception nor an error alone proves that nothing was written. *)

val id : t -> string
val revision : t -> string
val status : t -> status
val source : t -> Keeper_checkpoint_ref.t
val source_artifact_sha256 : t -> string
val pending_stimulus_ids : t -> string list
val required_source_refs : t -> string list
val source_watermark : t -> string
val cursor : t -> int
val projection_artifact_sha256 : projection -> string
val owner_instance_id : owner -> string
val owner_claim_id : owner -> string
val last_owner : t -> owner option
(** Terminal outcomes retain the submitting claim; None means unclaimed Pending. *)

val create
  :  config:Workspace.config
  -> keeper_name:Keeper_id.Keeper_name.t
  -> admission_id:string
  -> source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> failures:(string * Agent_core.Error.t) list
  -> pending_stimulus_ids:string list
  -> required_source_refs:string list
  -> source_watermark:string
  -> (t mutation, error) result
(** The exact snapshot is captured by the checkpoint owner before this call.
    Its canonical bytes are durably retained without re-encoding. The work ID
    binds Keeper/trace/admission, so a duplicate returns the existing work;
    changing that admission's source, requirements or refusal evidence conflicts.
    Required refs are owner-authored external identities; this boundary does not
    prove their membership in the checkpoint or their semantic coverage.
    Only a nonempty list of typed ContextOverflow failures is admitted. *)

val load : config:Workspace.config -> id:string -> (t option, error) result
(** Reads the validated ledger only. Missing/corrupt source artifacts do not
    hide owner/status evidence or prevent fail/cancel. This is not proof that
    source bytes are available. No process-local cache is authoritative. *)

val verify_artifacts : Workspace.config -> t -> (unit, error) result
(** Separately verifies actual source bytes/digest/checkpoint identity and any
    recorded proposal artifact. Claim and proposal publication require it;
    cursor bookkeeping and terminal recording do not re-read the whole source. *)

val claim
  :  config:Workspace.config
  -> id:string
  -> expected_revision:string
  -> instance_id:string
  -> ((t * owner) mutation, error) result
(** Claims Pending work or fences a previously Running claim with a fresh token.
    The caller is the existing Keeper Owner; it must stop/join an earlier live
    worker before re-claiming. This ledger does not detect process death or
    cancel workers. Reload/re-claim preserves the exact work ID and cursor. *)

val record_progress
  :  config:Workspace.config
  -> id:string
  -> owner:owner
  -> expected_revision:string
  -> next_offset:int
  -> (t mutation, error) result
(** Exact source-byte cursor, not a token/byte conversion or completeness proof. *)

val record_proposal
  :  config:Workspace.config
  -> id:string
  -> owner:owner
  -> expected_revision:string
  -> current_source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> claimed_required_refs:string list
  -> claimed_stimulus_ids:string list
  -> proposal_bytes:string
  -> (t mutation, error) result
(** Requires the claimed identity sets unchanged and the same exact checkpoint
    snapshot. The durable typed envelope retains source, owner and claimed refs;
    proposal_bytes is opaque unvalidated text stored in an immutable artifact.
    List equality does not prove the text actually covers these requirements.
    The supplied current snapshot is an observation; later application must
    independently CAS against the live checkpoint and pending-source owner. *)

val fail
  :  config:Workspace.config -> id:string -> owner:owner
  -> expected_revision:string -> failure -> (t mutation, error) result
val cancel
  :  config:Workspace.config -> id:string -> owner:owner
  -> expected_revision:string -> reason:string -> (t mutation, error) result
