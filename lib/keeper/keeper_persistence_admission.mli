(** Immutable-snapshot per-Keeper admission fence. Startup persistence recovery
    installs the baseline, and a request whose acceptance becomes ambiguous
    atomically extends only its BasePath/Keeper lane. A fenced lane must not
    execute new turns until an operator repairs the evidence and a later
    startup publishes a clean snapshot. *)

type install_error =
  | Base_path_identity_unavailable of
      { base_path : string
      ; cause : exn
      }

val install_error_to_string : install_error -> string

val install
  :  base_path:string
  -> blocked_keeper_names:string list
  -> (unit, install_error) result
(** [install] resolves BasePath exactly once and publishes both the raw and
    canonical identities atomically. Failure to establish the identity is a
    typed startup error; no partial fence is published. *)

type block_reason =
  | Recovery_failed
  | Reconciliation_required

val block_reason_to_wire : block_reason -> string

val block_reconciliation_required :
  base_path:string -> keeper_name:string -> unit
(** Atomically fence one Keeper after an accepted request's durability becomes
    ambiguous. The fence is BasePath-local and remains until a later startup
    installs a reconciled snapshot. *)

val block_reason : base_path:string -> keeper_name:string -> block_reason option
(** [block_reason] performs no filesystem I/O. It matches the supplied
    BasePath exactly against the raw or canonical identity captured by
    {!install}, and matches the Keeper name exactly. An unrelated BasePath
    never inherits another runtime's fence. *)

val is_blocked : base_path:string -> keeper_name:string -> bool

module For_testing : sig
  val clear : unit -> unit
end
