(** Lodge Personality — mood/trait to LLM parameter mapping.

    Application-level module (MASC, not OAS).
    Computes temperature from agent mood and curiosity trait.
    Optionally stores/reads personality state via OAS Context Custom scope. *)

(** Compute temperature from mood and curiosity.
    Pure function, no side effects.

    | Mood      | Base  | curiosity > 0.7 | Range       |
    |-----------|-------|-----------------|-------------|
    | Excited   | 0.8   | +0.1            | 0.8 - 0.9   |
    | Curious   | 0.65  | +0.1            | 0.65 - 0.75 |
    | Neutral   | 0.5   | +0.1            | 0.5 - 0.6   |
    | Satisfied | 0.4   | +0.1            | 0.4 - 0.5   |
    | Skeptical | 0.3   | +0.1            | 0.3 - 0.4   |
*)
val compute_temperature : mood:Lodge_daemon.mood -> curiosity:float -> float

(** Store personality state in OAS Context using Custom "personality" scope. *)
val store_in_context :
  Agent_sdk.Context.t -> mood:Lodge_daemon.mood -> curiosity:float -> unit

(** Read personality mood from OAS Context. Returns None if not stored. *)
val read_mood_from_context : Agent_sdk.Context.t -> Lodge_daemon.mood option

(** Read personality curiosity from OAS Context. Returns None if not stored. *)
val read_curiosity_from_context : Agent_sdk.Context.t -> float option
