(** MASC MCP Types — domain model facade.

    Re-exports the public surface of {!Ids}, {!Types_core}, and
    {!Types_auth} so callers can import a single namespace. The
    interface is computed via [include module type of …] so it
    auto-tracks the underlying modules without manual maintenance.

    Underlying modules currently have no [.mli] of their own; the
    inferred surface is what propagates here. When narrower [.mli]
    files land for those modules, this facade automatically picks up
    the tightened contract. *)

include module type of Ids
include module type of Types_core
include module type of Types_auth
