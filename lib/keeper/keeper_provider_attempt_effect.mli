(** Typed observation of tool effects within one provider candidate attempt.

    This public projection is manifestly equal to the leaf SSOT used by the
    durable failure codec. Provider error text and subtypes never grant retry
    authority. *)

type t = Keeper_provider_attempt_effect_core.t =
  | No_effect_observed
      (** No dynamic tool invocation was observed. *)
  | Effect_attempted
      (** A dynamic tool handler was entered; another candidate could duplicate
          the effect. *)
  | Observation_unavailable
      (** The adapter cannot prove whether an effect was attempted. *)

val allows_same_turn_retry : t -> bool
val to_string : t -> string
