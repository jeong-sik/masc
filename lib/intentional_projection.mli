(** Intentional Projection — Master Report Dim01 / P0 #6.

    Given a sequence of past actions and a list of candidate next actions,
    rank the candidates by how likely each is to be the user's intended
    next action. The default predictor is a 1st-order Markov / bigram
    model with additive Laplace smoothing — deliberately small and
    deterministic so that the cockpit can call it on every focus change
    without a budget concern.

    Like {!Cognitive_gravity} this module is intentionally pure: no I/O,
    no Eio, no global state. Sequences come from the caller (typically
    the dashboard or a keeper turn log); the model returns a fresh value
    on every observation. See `docs/rfc/RFC-0035-cognitive-ide-roadmap.md`
    (PR-2) for the integration plan. *)

(** A single observed transition: action [prev] was followed by [next]. *)
type transition = {
  prev : string;
  next : string;
}

(** Opaque bigram model. Build it with {!empty} and {!observe_pairs}; the
    only way to read it is via {!score} and {!rank}. *)
type model

(** Empty model with no observations. *)
val empty : model

(** Convert a sequence of actions [a_0; a_1; ...; a_n] to its bigram
    pairs [{prev=a_0; next=a_1}; {prev=a_1; next=a_2}; ...]. Lists
    shorter than two elements yield the empty list. *)
val pairs_of_sequence : string list -> transition list

(** Add observed transitions to the model and return the new model. *)
val observe_pairs : model -> transition list -> model

(** Total observations recorded with [prev]. Useful for tests and for
    ratio-based confidence reporting; not part of the ranking path. *)
val total_after : model -> string -> int

(** [score model ~smoothing ~prev ~candidates ~next] returns the smoothed
    conditional probability that [next] follows [prev], normalised over
    the supplied [candidates] set.

    With [smoothing = 0.0] the score reduces to the maximum-likelihood
    estimate, which is [0.0] for unseen [prev] or unseen [(prev, next)]
    pairs. With [smoothing > 0.0] every candidate receives at least
    [smoothing / (smoothing * |candidates|)] mass, so the function never
    returns [0.0] when [smoothing > 0.0] and [candidates] is non-empty.

    The function returns [0.0] when [candidates] is empty. *)
val score :
  model ->
  smoothing:float ->
  prev:string ->
  candidates:string list ->
  next:string ->
  float

(** [rank model ~smoothing ~prev ~candidates] applies {!score} to every
    candidate and returns them paired with their scores, sorted by
    descending score. The sort is stable: candidates with equal scores
    retain their input order. *)
val rank :
  model ->
  smoothing:float ->
  prev:string ->
  candidates:string list ->
  (string * float) list
