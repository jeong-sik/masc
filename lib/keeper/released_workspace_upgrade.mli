(** Explicit, offline repair of the released v0.34 Keeper activation schema.
    Assessment is read-only. No Goal proof identities or missing defaults are
    inferred. Each file is an independent transaction with its own backup. *)
type plan

type assessment =
  | Compatible
  | Upgrade_available of plan
  | Manual_repair_required

val assess_keeper : path:string -> string -> assessment
val plan_to_json : plan -> Yojson.Safe.t

type receipt

type error =
  | Workspace_in_use
  | Unsafe_path
  | Source_changed
  | Backup_failed
  | Replacement_failed

(** Acquires the same exclusive BasePath lease as server startup. [run_dir]
    must be the server's configured lease directory. Requires an existing
    workspace; never initializes it. Exact assessed bytes must still match. *)
val error_message : error -> string

(** Acquires the same exclusive BasePath lease as server startup. [run_dir]
    must be the server's configured lease directory. Requires an existing
    workspace; never initializes it. Exact assessed bytes must still match. *)
val apply : run_dir:string -> base_path:string -> plan -> (receipt, error) result
(** Restores only if the file still equals this migration's exact output.
    The original backup remains available after restoration. *)

(** Restores only if the file still equals this migration's exact output.
    The original backup remains available after restoration. *)
type restoration =
  { durability_confirmed : bool
  ; lock_release_confirmed : bool
  }

val restore : run_dir:string -> base_path:string -> receipt -> (restoration, error) result

(** Reopens a previously published backup after a process restart. The identifier
    is the generated backup directory basename, not an arbitrary path. Validates
    the stored plan against the original bytes and the current typed converter. *)
val receipt_to_json : receipt -> Yojson.Safe.t

(** Reopens a previously published backup after a process restart. The identifier
    is the generated backup directory basename, not an arbitrary path. Validates
    the stored plan against the original bytes and the current typed converter. *)
val load_recovery : base_path:string -> backup_id:string -> (receipt, error) result

module For_testing : sig
  val restore_with_parent_sync
    :  sync_parent:(string -> unit)
    -> run_dir:string
    -> base_path:string
    -> receipt
    -> (restoration, error) result
end
