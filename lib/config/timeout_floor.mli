(** Typed timeout floors for load-bearing timeout clamps.

    Floors differ from ordinary defaults: lowering them can reintroduce
    known failure modes such as sub-network-latency gh calls or Docker
    cold-start truncation. Keep those decisions in one typed table
    instead of scattering magic literals at call sites. *)

type t =
  | Docker_run
  | Native_shell
  | Tool_dispatch
  | Llm_call
  | Other of string

val to_string : t -> string
val default_sec : t -> float
val clamp : t -> float -> float
val is_load_bearing : t -> bool
