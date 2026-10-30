(** MASC MCP Types — domain model facade.

    Re-exports the public surface of {!Ids}, {!Types_core}, and
    {!Types_auth} so callers can import a single namespace. The
    interface is computed via [include module type of …] so it
    auto-tracks the underlying modules without manual maintenance.

    Underlying modules currently have no [.mli] of their own; the
    inferred surface is what propagates here. When narrower [.mli]
    files land for those modules, this facade automatically picks up
    the tightened contract. *)

(** Strengthened re-export: [module type of struct include M end]
    forces manifest type identity through the facade
    ([Types.task = Types_core.task = { ... }]), preventing nominal
    drift when callers mix [open Types] with direct
    [Types_core.<symbol>] references in [.mli] signatures. *)

include module type of struct include Ids end
include module type of struct include Types_core end
include module type of struct include Types_auth end
