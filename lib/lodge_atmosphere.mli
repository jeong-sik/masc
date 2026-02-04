(** Lodge Atmosphere — lightweight mood signal for prompts

    Provides a stable, low-cost signal to guide tone.
    Default is neutral; can be overridden by MASC_LODGE_ATMOSPHERE env var.

    @since 2.49.0 *)

(** Get current atmosphere value (0.0 to 1.0, default 0.5) *)
val get_value : unit -> float

(** Get human-readable atmosphere description *)
val get_description : unit -> string
