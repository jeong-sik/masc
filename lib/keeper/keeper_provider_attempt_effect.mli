(** Typed observation of tool effects within one provider candidate attempt.

    This value is carried separately from the provider error. Provider error
    text and subtypes are diagnostic evidence; they must never be parsed to
    recover whether trying another candidate could repeat an external effect. *)

type t =
  | No_effect_observed
      (** The attempt boundary did not observe a dynamic tool invocation. This
          does not override another retry fence such as an AGENT_CORE checkpoint. *)
  | Effect_attempted
      (** A dynamic tool handler was entered. The effect may have committed, so
          another provider candidate must not receive the same turn. *)
  | Observation_unavailable
      (** This runtime path has no complete tool-effect observer. Same-turn
          retry is fail-closed until the adapter supplies one. *)

(** [allows_same_turn_retry disposition] is the effect-side half of the
    same-turn retry gate. Callers must compose it with every other retry
    authority, notably the typed AGENT_CORE checkpoint fence. Unknown
    observation is denied rather than treated as evidence of no effect. *)
val allows_same_turn_retry : t -> bool
