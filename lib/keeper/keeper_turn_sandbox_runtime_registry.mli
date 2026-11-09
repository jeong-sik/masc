(** What the process knows about guests apart from any one turn: the types of a
    GitHub identity snapshot, the table that registers a process-owned snapshot
    under a guest name, the lifecycle lock of one Keeper's guest and the
    inventory lock that excludes all of them, and the sweep of abandoned
    process-bound guests.

    [Keeper_turn_sandbox_runtime] includes this module. *)

type process_github_identity_snapshot =
  { args : string list
  ; host_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

type github_identity_snapshot =
  | Process_identity of process_github_identity_snapshot
  | Guest_identity of Keeper_microvm_github_identity.snapshot

val identity_host_dir : github_identity_snapshot -> string

val identity_revision : github_identity_snapshot -> string

type github_identity_snapshots =
  { current : github_identity_snapshot option
  ; retired : github_identity_snapshot list
  }

val no_github_identity_snapshots : github_identity_snapshots

val microvm_lifecycle : Keeper_microvm_lifecycle.t

val with_microvm_lifecycle_lock :
  keeper_name:string -> operation:string -> (unit -> 'a) -> 'a

val with_microvm_inventory_lock : (unit -> 'a) -> 'a

val sweep_process_bound_microvm_guests :
  base_path:string ->
  command_available:(string -> bool) ->
  timeout_sec:float ->
  is_pid_alive:(int -> bool) ->
  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string) ->
  (Keeper_microvm_backend.t * Keeper_sandbox_microvm.sweep_outcome) list

val microvm_identity_snapshot :
  string -> process_github_identity_snapshot option

val claim_microvm_identity_snapshot :
  string ->
  process_github_identity_snapshot ->
  [> `Claimed | `Existing of process_github_identity_snapshot ]

val release_registered_microvm_identity :
  ?expected:process_github_identity_snapshot -> string -> unit
