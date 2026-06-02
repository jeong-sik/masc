(** Forward-looking continuity summary filtering.

    Private helper for {!Keeper_memory_policy}; keeps the public API stable
    while isolating prompt-facing string scrub rules from snapshot parsing. *)

val filter_forward_looking_summary : string -> string
