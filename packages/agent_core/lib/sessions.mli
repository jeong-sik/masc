(** Sessions — public API facade.

    Re-exports types from {!Sessions_types} and store operations from
    {!Sessions_store}.

    @stability Evolving
    @since 0.93.1 *)

include module type of Sessions_types
include module type of Sessions_store
