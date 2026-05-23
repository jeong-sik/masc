(** Deterministic error recovery field generation.

    Pure logic for extracting structured recovery plans from
    deterministic failure payloads. No mutable state.

    @since P3 extraction *)

(** Promote a tool-specific [recovery_plan] out of a deterministic
    failure payload so required-tool turns can route the next call
    without scraping nested detail text. *)
val deterministic_recovery_plan_fields : string -> (string * Yojson.Safe.t) list

