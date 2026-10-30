(** Canonical dependency-leaf contract for one tool invocation.

    This module depends only on JSON and the standard library. Tool handlers,
    runtime state, providers, and errors must depend on this contract, never the
    reverse.

    @stability Evolving
    @since 0.221.0 *)

module Resource_scope : sig
  type identity
  type identity_error = Empty_namespace | Empty_key
  type access = Read | Write
  type t

  val identity : namespace:string -> key:string -> (identity, identity_error) result
  val create : access:access -> occupied:identity -> ancestors:identity list -> t
  val conflicts : t -> t -> bool
  (** Overlapping claims conflict when either carries [Write]. Two [Read]
      claims may overlap, including an ancestor and its descendant. Overlap
      means equal occupied identities, or one occupied identity in the other's
      ancestry; a shared ancestor alone does not make disjoint siblings overlap.
      The producer owns access classification, identity resolution and complete
      ancestry. [Read] describes this resource only, not the whole call's effect,
      permission or replay contract. A call may carry several read/write claims. *)
end

type execution_mode =
  | Concurrent
  | Serial
[@@deriving show]

val execution_mode_to_yojson : execution_mode -> Yojson.Safe.t
val execution_mode_of_yojson : Yojson.Safe.t -> (execution_mode, string) result

type failure_effect_disposition =
  | Proven_pre_effect
  | Proven_post_effect
  | Effect_outcome_unknown
[@@deriving show]

type completion =
  | Continue_after_success
  | Terminal_after_success of failure_effect_disposition
[@@deriving show]

val completion_to_yojson : completion -> Yojson.Safe.t
val completion_of_yojson : Yojson.Safe.t -> (completion, string) result

type schedule =
  { planned_index : int
  ; batch_index : int
  ; batch_size : int
  ; execution_mode : execution_mode
  }
(** Planned invocation coordinates. Resource-scoped execution preserves the
    deterministic wave index/size while admitting successors after their own
    conflicting predecessors settle. Equal wave coordinates describe a planned
    cohort; later coordinates do not impose an unrelated peer-completion
    barrier. They grant no effect, replay or permission authority. *)

module Occurrence : sig
  (** Exact canonical citation, never an effect/approval/replay capability.
      Construction wraps already-selected journal identities without minting. *)
  type t
  type error = Empty_run_id | Empty_node_id | Padded_run_id | Padded_node_id
  val of_strings : run_id:string -> node_id:string -> (t,error) result
  val run_id : t -> string
  val node_id : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Invocation : sig
  type t

  val create
    :  tool_use_id:string
    -> turn:int
    -> schedule:schedule
    -> completion:completion
    -> t

  val of_occurrence : Occurrence.t -> tool_use_id:string -> turn:int ->
    schedule:schedule -> completion:completion -> t
  val occurrence : t -> Occurrence.t option
  (** [None] is an explicitly non-journalled invocation. *)
  val tool_use_id : t -> string
  val turn : t -> int
  val schedule : t -> schedule
  val completion : t -> completion
  val planned_index : t -> int
end
