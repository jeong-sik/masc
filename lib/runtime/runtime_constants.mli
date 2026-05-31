(** Runtime numeric constants (RFC-0206). Re-homed from deleted [Cascade_runtime]. *)

val fallback_context_window : int
(** Context-window size assumed when a model declares none and discovery yields
    nothing (128000). Mirrors deleted [Runtime_constants.fallback_context_window]. *)

(** Worker-turn sampling defaults, re-homed from the deleted
    [Cascade_worker_defaults] (RFC-0206). *)
module Worker_sampling : sig
  val top_p : float
  val top_k : int
  val max_tool_calls_per_turn : int
end
