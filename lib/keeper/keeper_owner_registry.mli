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
  | Inventory_stopping

exception Install_failed of install_error

val install_from_store
  :  sw:Eio.Switch.t
  -> Workspace.config
  -> (int, install_error) result
(** Strictly load every persisted Keeper and start exactly one owner actor for
    each under [sw].  Returns the installed owner count. *)

val ensure
  :  base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_owner.t, lookup_error) result
(** Start the owner for a newly created Keeper, or return the existing owner.
    Name collisions never replace an existing actor. *)

val get
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_owner.t, lookup_error) result

val all_projections
  :  base_path:string
  -> (Keeper_owner_reducer.projection list, lookup_error) result
(** Lock-free fleet projection. *)

val install_error_to_string : install_error -> string
val lookup_error_to_string : lookup_error -> string

module For_testing : sig
  val installed_owner_count : base_path:string -> int
end
