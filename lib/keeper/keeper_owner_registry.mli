(** Process-local inventory of per-Keeper owners.

    The existing BasePath process lease remains the authority.  This module
    adds no process lease, worker epoch, or persistent ownership record. *)

type install_error =
  | Inventory_already_installed of string
  | Inventory_load_failed of
      { keeper_name : string option
      ; detail : string
      }

type lookup_error =
  | Inventory_not_installed of string
  | Owner_not_found of string
  | Owner_unavailable of string
  | Owner_initialization_failed of Keeper_owner.error
  | Inventory_stopping

type command_error =
  | Command_lookup_failed of lookup_error
  | Command_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Command_rejected of Keeper_owner.error

exception Install_failed of install_error

val install_from_store
  :  sw:Eio.Switch.t
  -> operation_runner:Keeper_owner.operation_runner option
  -> on_turn_slot_released:(keeper_name:string -> unit) option
  -> Workspace.config
  -> (int, install_error) result
(** Load each valid persisted Keeper independently and start exactly one owner
    actor for it under [sw]. A snapshot the store reads as absent (the file is
    gone, or it does not decode under the current schema, which the store
    reports at WARN) is not in the inventory: the name stays unknown to the
    pool and [create_meta] materialises it, at boot from its TOML declaration.
    A snapshot the store cannot read at all, or whose payload identity differs
    from its path, is reported and fenced under its exact Keeper name without
    preventing other owners from starting; that name cannot be read, created,
    or mutated until process restart re-audits durable state. Failure to
    enumerate the inventory still fails installation. Returns the installed
    owner count. *)

val get
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_owner.t, lookup_error) result

val operation_projection
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_owner.operation_projection, lookup_error) result
(** Lock-free immutable operation inventory for routine read models. *)

val wake_operation_drain
  :  base_path:string
  -> keeper_name:string
  -> (unit, command_error) result
(** Notify one Owner that its operation runner dependency is ready. *)

val run_autonomous_if_idle
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of Keeper_owner.autonomous_block ], command_error) result
(** Submit one autonomous turn attempt to the Keeper's Owner mailbox. *)

val run_maintenance_if_idle
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of Keeper_owner.autonomous_block ], command_error) result
(** Submit one exclusive maintenance attempt to the Keeper's Owner mailbox. *)

val shutdown_operation_id
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_shutdown_types.Operation_id.t option, lookup_error) result

val begin_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (Keeper_owner.begin_shutdown_result, command_error) result

val rollback_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (Keeper_owner.rollback_shutdown_result, command_error) result

val restore_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (Keeper_owner.restore_shutdown_result, command_error) result

val transition_shutdown
  :  base_path:string
  -> keeper_name:string
  -> from_operation_id:Keeper_shutdown_types.Operation_id.t
  -> to_operation_id:Keeper_shutdown_types.Operation_id.t option
  -> (Keeper_owner.transition_shutdown_result, command_error) result

val await_idle_after_shutdown
  :  base_path:string
  -> keeper_name:string
  -> (unit, command_error) result
(** Join the Owner child and durable intake that preceded its shutdown
    reservation. *)

val apply_meta
  :  ?lifecycle_token:Keeper_lifecycle_reservation.token
  -> base_path:string
  -> keeper_name:string
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, command_error) result
(** Mailbox-linearized metadata mutation.  Registry metadata is refreshed only
    from the committed owner projection.  The existing lifecycle reservation
    remains the admission authority through the owner commit. *)

val commit_turn_runtime
  :  base_path:string
  -> keeper_name:string
  -> before:Keeper_meta_contract.keeper_meta
  -> after:Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta option, command_error) result
(** Derive and commit only the closed turn delta. Cumulative fields are added
    to the actor's current snapshot; callers cannot overwrite the record. *)

val create_meta
  :  ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta option, command_error) result
(** Under the durable-intake fence, install an empty actor for a new Keeper,
    then commit its first snapshot via the closed [Create] command. A failed
    commit leaves the empty actor in place so same-name retries remain
    mailbox-linearized. An active shutdown reservation rejects creation before
    an empty actor is installed. When [intake_token] is supplied, the caller's
    already-open exact-name intake transaction is reused instead of reacquiring
    the same fence. *)

val exact_operation
  :  base_path:string
  -> keeper_name:string
  -> Keeper_chat_operation.Operation_id.t
  -> (Keeper_chat_operation.t option, command_error) result

val interrupt_running_operation
  :  base_path:string
  -> keeper_name:string
  -> Keeper_chat_operation.Operation_id.t
  -> (Keeper_owner.operation_interrupt_result, command_error) result
(** Mailbox-linearized exact-operation interrupt. A request naming an older
    operation cannot cancel a newer child for the same Keeper. *)

val submit_operation
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_chat_operation.Operation_id.t
  -> source:Yojson.Safe.t
  -> input:Yojson.Safe.t
  -> (Keeper_owner.operation_acceptance, command_error) result

val list_queued_operations
  :  base_path:string
  -> keeper_name:string
  -> after_sequence:int64 option
  -> limit:int
  -> (Keeper_chat_operation.t list, command_error) result

val edit_queued_operation
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_chat_operation.Operation_id.t
  -> input:Yojson.Safe.t
  -> (Keeper_chat_operation.t, command_error) result

val move_queued_operation_to_end
  :  base_path:string
  -> keeper_name:string
  -> Keeper_chat_operation.Operation_id.t
  -> (Keeper_chat_operation.t, command_error) result

val cancel_queued_operation
  :  base_path:string
  -> keeper_name:string
  -> Keeper_chat_operation.Operation_id.t
  -> (Keeper_chat_operation.t, command_error) result

val all_projections
  :  base_path:string
  -> (Keeper_owner_reducer.projection list, lookup_error) result
(** Lock-free fleet projection. *)

val begin_stopping_all
  :  base_path:string
  -> ((unit, Keeper_owner.error) result list, lookup_error) result
(** Fence the BasePath inventory, concurrently stop every Owner, and return
    after each active child has joined its terminal persistence attempt. *)

val install_error_to_string : install_error -> string
val lookup_error_to_string : lookup_error -> string
val command_error_to_string : command_error -> string

module For_testing : sig
  val installed_owner_count : base_path:string -> int
end

val heap_root : (Obj.t -> 'a) -> 'a
(** Run [walk] on this module's retained state, under the lock that guards
    it, for [Heap_roots.measure] to size with [Obj.reachable_words].
    Diagnostics only: the walk stalls the process for its duration. *)
