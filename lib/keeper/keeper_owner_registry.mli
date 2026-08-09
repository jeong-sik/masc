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
  | Owner_initialization_failed of Keeper_owner.error
  | Inventory_stopping

type command_error =
  | Command_lookup_failed of lookup_error
  | Command_lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Command_rejected of Keeper_owner.error

exception Install_failed of install_error

val install_from_store
  :  sw:Eio.Switch.t
  -> Workspace.config
  -> (int, install_error) result
(** Strictly load every persisted Keeper and start exactly one owner actor for
    each under [sw].  Returns the installed owner count. *)

val get
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_owner.t, lookup_error) result

val apply_meta
  :  ?lifecycle_token:Keeper_lifecycle_reservation.token
  -> base_path:string
  -> keeper_name:string
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, command_error) result
(** Mailbox-linearized metadata mutation.  Registry metadata is refreshed only
    from the committed owner projection.  The existing lifecycle reservation
    remains the admission authority through the owner commit. *)

val create_meta
  :  base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta option, command_error) result
(** Install an empty actor for a new Keeper, then commit its first snapshot via
    the closed [Create] command.  A failed commit leaves the empty actor in
    place so same-name retries remain mailbox-linearized. *)

val all_projections
  :  base_path:string
  -> (Keeper_owner_reducer.projection list, lookup_error) result
(** Lock-free fleet projection. *)

val install_error_to_string : install_error -> string
val lookup_error_to_string : lookup_error -> string
val command_error_to_string : command_error -> string

module For_testing : sig
  val installed_owner_count : base_path:string -> int
end
