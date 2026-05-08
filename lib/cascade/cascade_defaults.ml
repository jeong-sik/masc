(** Default cascade constants.

    Defined in a standalone module to avoid circular dependencies:
    [Keeper_cascade_profile] depends on [Cascade_routes] for routing
    helpers, so [Cascade_routes] cannot reference [Keeper_cascade_profile]
    directly. *)

(** Last-resort fallback profile name for keeper-assignable routes.
    Used when the live catalog has no keeper-assignable entries. *)
let keeper_fallback_profile = "big_three"
