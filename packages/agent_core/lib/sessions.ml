(** Sessions — public API facade.

    Re-exports types from Sessions_types and store operations from
    Sessions_store. *)

include Sessions_types
include Sessions_store
