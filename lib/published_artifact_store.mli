(** Durable publication authority. No chat or Board messages are emitted. *)
type error =
  | Invalid of string
  | Missing
  | Conflict of { expected : int; actual : int }
  | Unavailable of string
  | Commit_uncertain of { id : string; revision : int; message : string }
type listing =
  { artifacts : Yojson.Safe.t list
  ; diagnostics : (string * string) list
  }
val error_message : error -> string
val publish : base_path:string -> author:string -> Published_artifact.request ->
  (Published_artifact.t * Published_artifact.revision, error) result
(** On a revision, an omitted Task or Goal reference retains the preceding
    revision's reference, JSON null clears it and a string sets it. Creation
    treats omitted and null references as absent. *)
val list : base_path:string -> (listing, error) result
val list_with_authors : base_path:string -> (listing, error) result
(** The same latest-publication inventory and diagnostics as [list], with an
    [authors] array containing all distinct authors recorded in each artifact's
    revision history. This is a metadata read; it does not read revision bodies
    or establish current editor presence. *)
val read : base_path:string -> id:string -> revision:int option ->
  (Published_artifact.t * Published_artifact.revision * string, error) result
val with_latest_locked : base_path:string -> id:string -> expected_revision:int ->
  f:(Published_artifact.revision -> string -> 'a) -> ('a, error) result
(** Acquire the same per-artifact lock as [publish], then read and validate the
    current revision and its exact source before calling [f]. The callback is
    not called if the current revision differs from [expected_revision]. Its
    value is preserved if lock release reports an error; exceptions, including
    cancellation, are propagated after release. The callback runs in a system
    thread and must use blocking operations only, without Eio effects; it must
    not publish or acquire this artifact's publication lock recursively. This only locks
    the publication: callers coordinating another store must also use that
    store's own concurrency boundary. *)
val is_shared : base_path:string -> id:string -> (bool, error) result
val set_shared : base_path:string -> id:string -> shared:bool -> (bool, error) result

type share_error =
  | Share_invalid of string
  | Share_missing
  | Share_operation_reused
  | Share_unavailable of string
  | Share_commit_uncertain of Published_artifact_share.receipt

val share_error_message : share_error -> string
val read_share : base_path:string -> id:string -> (Published_artifact_share.snapshot, share_error) result
(** An interrupted first change may be settled under the publication lock
    before its snapshot can be read. A reported uncertain change can therefore
    take effect during a subsequent read. *)
val read_with_share : base_path:string -> id:string -> revision:int option -> allow_private:bool ->
  ([ `Private | `Allowed of Published_artifact_share.snapshot * Published_artifact.t * Published_artifact.revision * string ],
   [ `Share of share_error | `Artifact of error ]) result
(** Select the revision and check sharing under the publication lock. The
    content-addressed body is loaded after releasing that lock. *)
val find_share_receipt : base_path:string -> id:string -> operation_id:string ->
  (Published_artifact_share.receipt option, share_error) result
(** [None] is not proof that an in-flight request will never apply. A visible
    receipt from an uncertain commit is an observation, not by itself proof
    that the directory entry survived a crash. *)
val change_share : base_path:string -> id:string -> Published_artifact_share.request ->
  (Published_artifact_share.receipt, share_error) result
(** The share version and latest publication revision/digest are checked while
    holding the publication lock. The sharing state and latest receipt commit
    in one file. Before replacing that file, the store
    settles it and archives its receipt durably. Replaying an identical
    operation settles the current snapshot before returning the original
    receipt. A different request with the same operation ID is refused.
    Receipts consume disk space until an explicit retention scheme is added;
    backups and restores must preserve the snapshot, guard and receipt tree
    together. Missing historical receipt files cannot be distinguished from
    unused IDs. All writers must use this protocol; older binaries cannot be
    mixed with it. *)

module For_testing : sig
  val read_with_share_after_select : after_select:(unit -> unit) -> base_path:string -> id:string ->
    revision:int option -> allow_private:bool ->
    ([ `Private | `Allowed of Published_artifact_share.snapshot * Published_artifact.t * Published_artifact.revision * string ],
     [ `Share of share_error | `Artifact of error ]) result
  val change_share_before_stage : before_stage:(Keeper_fs.durable_write_stage -> unit) ->
    base_path:string -> id:string -> Published_artifact_share.request ->
    (Published_artifact_share.receipt, share_error) result
end
