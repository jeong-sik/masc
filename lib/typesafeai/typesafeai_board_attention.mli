(** TypeSafe AI System One adapter for Board Attention Candidate judgment.
    Evaluates relevance in one System One request that returns a choice with
    its confidence, bypassing free-text LLM generation. *)

type assessment =
  | Decided of Keeper_board_attention_judgment.t
  | Needs_review of string
(** An explicit uncertainty answer requests the full judgment lane. *)

type judged =
  { assessment : assessment
  ; provenance : Keeper_board_attention_candidate.system_one_provenance
      (** The configured destination, exact request-body digest, and the model
          the System One response says answered. *)
  ; confidence : float
      (** Validated 0..1 confidence retained for observation, never routing. *)
  }

val judge_candidate :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  destinations:Typesafeai_config.destinations ->
  candidate:Keeper_board_attention_candidate.candidate ->
  unit ->
  (judged, string) result
(** Evaluates the current signal with explicit relevant, not_relevant and
    uncertain choices. Uncertainty is [Needs_review]; confidence is observation
    only. Returns [Error] for transport, invalid response or unoffered choice. *)
