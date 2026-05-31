(** Runtime numeric constants (RFC-0206 runtime→Runtime rebirth).

    Re-homes the constants that lived on the deleted [Runtime_runtime] module
    and were referenced by surviving consumers (relay, dashboard health,
    context compaction). No routing/catalog state — pure named values. *)

(** Context-window size assumed when a model declares none and discovery
    yields nothing. Mirrors the deleted [Runtime_constants.fallback_context_window].
    128k is the conservative floor across the supported provider matrix. *)
let fallback_context_window = 128_000
