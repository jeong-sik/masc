(** Lodge Personality — mood/trait to LLM parameter mapping.

    Application-level module (MASC, not OAS).
    Computes temperature from agent mood and curiosity trait.
    Optionally stores/reads personality state via OAS Context Custom scope.

    Design rationale:
    - Temperature is the primary knob for conversation variety.
    - Mood determines the base temperature; curiosity adds a bonus.
    - This is a pure computation module with no LLM calls.
    - OAS Context is used only as a data transport, not for decision logic.

    @since 3.0.0 *)

let personality_scope = Agent_sdk.Context.Custom "personality"

(** Base temperature per mood.
    Skeptical (low variance, factual) → Excited (high variance, creative). *)
let base_temperature_of_mood = function
  | Lodge_daemon.Excited   -> 0.8
  | Lodge_daemon.Curious   -> 0.65
  | Lodge_daemon.Neutral   -> 0.5
  | Lodge_daemon.Satisfied -> 0.4
  | Lodge_daemon.Skeptical -> 0.3

let compute_temperature ~mood ~curiosity =
  let base = base_temperature_of_mood mood in
  let curiosity_bonus = if curiosity > 0.7 then 0.1 else 0.0 in
  Float.min 1.0 (base +. curiosity_bonus)

(** {1 OAS Context integration} *)

let store_in_context (ctx : Agent_sdk.Context.t) ~mood ~curiosity =
  Agent_sdk.Context.set_scoped ctx personality_scope
    "mood" (`String (Lodge_daemon.string_of_mood mood));
  Agent_sdk.Context.set_scoped ctx personality_scope
    "curiosity" (`Float curiosity);
  Agent_sdk.Context.set_scoped ctx personality_scope
    "temperature" (`Float (compute_temperature ~mood ~curiosity))

let read_mood_from_context (ctx : Agent_sdk.Context.t) =
  match Agent_sdk.Context.get_scoped ctx personality_scope "mood" with
  | Some (`String s) -> Some (Lodge_daemon.mood_of_string s)
  | _ -> None

let read_curiosity_from_context (ctx : Agent_sdk.Context.t) =
  match Agent_sdk.Context.get_scoped ctx personality_scope "curiosity" with
  | Some (`Float f) -> Some f
  | _ -> None
