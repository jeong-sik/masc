(** Keeper_tooling.Response - provider response acceptance. *)

type accept_rejection_kind =
  | No_usable_progress
  | Predicate_rejected

type accept_rejection =
  { kind : accept_rejection_kind
  ; reason : string
  ; response_shape : Agent_core.Response_shape.content_shape option
  }

(** Format an accept rejection reason for a runtime attempt. When the built-in
    keeper progress contract would accept the response, the returned reason is
    tagged as a caller-specific predicate rejection instead of no-progress. *)
val accept_rejection_of_response :
  runtime_id:string -> Agent_core.Types.api_response -> accept_rejection

(** [false] when the provider cut the response at its output limit
    ([MaxTokens]), even when it carries text, so the turn can resume from its
    post-turn checkpoint. A model that ends its turn ([EndTurn]) may end it
    with blank text, no content or reasoning alone. Any other stop needs
    deliverable content. No provider/model name or free-form response text
    participates in the decision. *)
val accepts_response : Agent_core.Types.api_response -> bool
