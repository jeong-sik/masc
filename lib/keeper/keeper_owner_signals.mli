(** Signals the Keeper owner raises into a turn, readable by runtime adapters.

    See the implementation for why this module exists separately from
    [Keeper_owner]: the owner calls the adapters, so they cannot depend on it,
    and an exception declaration depends on nothing. *)

exception Stop_active_child
