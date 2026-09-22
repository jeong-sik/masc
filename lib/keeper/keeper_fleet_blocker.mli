(** The first reason the keeper fleet is short of what it is configured to
    run, as the fleet scan reports it in [blocker].

    The scan checks them in the order of this type and names the first that
    holds. The server writes the wire name; the terminal client reads it back
    through {!of_wire_name}, so neither side keeps its own copy. *)

type t =
  | Keeper_bootstrap_disabled
      (** Keeper boot is switched off and no keeper can take a turn. *)
  | No_executable_keeper_fibers  (** No keeper fiber can run a turn. *)
  | Turn_configuration_error
      (** A keeper's turn configuration is invalid, and retrying will not
          change it. *)
  | Official_client_recovery_required
      (** An official-client keeper's session needs an explicit recovery. *)
  | Reaction_capacity_below_target
      (** Fewer keepers can react than the fleet is configured for. *)
  | Active_task_owner_without_executable_fiber
      (** A keeper that owns an active task has no fiber that can run it. *)
  | Durable_paused_autoboot_enabled
      (** Keepers set to boot on their own are held by a durable pause. *)

val all : t list
(** Every value, once each. *)

val wire_name : t -> string

val of_wire_name : string -> t option
(** [None] for a name this build does not know -- a newer server's reason. *)
