(** TypeSafe AI System One adapter for Board Attention Candidate judgment.
    Evaluates relevance in one System One request that returns a choice with
    its confidence, bypassing free-text LLM generation. *)

type judged =
  { verdict : Keeper_board_attention_judgment.t
  ; provenance : Keeper_board_attention_candidate.system_one_provenance
      (** The configured destination, exact request-body digest, and the model
          the System One response says answered. *)
  }

val judge_candidate :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  api_key:string ->
  candidate:Keeper_board_attention_candidate.candidate ->
  material:Keeper_board_attention_candidate.judgment_material ->
  unit ->
  (judged, string) result
(** Evaluates a pending candidate using TypeSafe AI Jev and returns the
    decision Jev picked, whichever it is; what a decision leads to is the
    caller's. The confidence and probabilities Jev reported are kept in the
    verdict's rationale for the record and are not compared against anything.
    Returns [Error reason] if the question's option set is rejected by
    {!Typesafeai_types.choice_set}, the HTTP call fails, the response does not
    decode, or Jev picks an option the question did not offer. *)
