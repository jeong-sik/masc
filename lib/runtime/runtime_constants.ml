(** Runtime numeric constants (RFC-0206 cascade→Runtime rebirth).

    Re-homes the constants that lived on the deleted [Cascade_runtime] module
    and were referenced by surviving consumers (relay, dashboard health,
    context compaction). No routing/catalog state — pure named values. *)

(** Context-window size assumed when a model declares none and discovery
    yields nothing. Mirrors the deleted [Runtime_constants.fallback_context_window].
    128k is the conservative floor across the supported provider matrix. *)
let fallback_context_window = 128_000

(** Worker-turn sampling defaults, re-homed from the deleted
    [Cascade_worker_defaults]. Local/container worker turns send these to the
    completion endpoint when the caller does not override them. Values verbatim
    from the pre-purge module (RFC-0206 cascade→Runtime rebirth). *)
module Worker_sampling = struct
  let top_p = 0.95
  let top_k = 20
  let max_tool_calls_per_turn = 12
end
