(** TypeSafe AI System One adapter for Board Attention Candidate judgment.
    Evaluates relevance in one System One request that returns a choice with
    calibrated confidence, bypassing free-text LLM generation. *)

val min_confidence_threshold : float
(** Minimum confidence required to accept a Jev judgment without fallback (default 0.5). *)

type judged =
  { verdict : Keeper_board_attention_judgment.t
  ; model : string
      (** The model the System One response says answered, which is not
          necessarily the one the request named. *)
  }

val judge_candidate :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?confidence_threshold:float ->
  api_key:string ->
  candidate:Keeper_board_attention_candidate.candidate ->
  material:Keeper_board_attention_candidate.judgment_material ->
  unit ->
  (judged, string) result
(** Evaluates a pending candidate using TypeSafe AI Jev.
    Returns [Error reason] if the HTTP call fails, JSON parsing fails,
    or confidence is below [confidence_threshold], allowing transparent fallback. *)
