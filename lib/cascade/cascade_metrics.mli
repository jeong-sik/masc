(** Cascade_metrics — Prometheus emit helpers for cascade routing observability. *)

val on_decision : cascade_name:string -> decision_label:string -> unit
val on_fallback : cascade_name:string -> reason:string -> unit
val on_exhausted : cascade_name:string -> unit
val on_phase_override : phase:string -> from_cascade:string -> to_cascade:string -> unit
