(** Which runtime answered a Keeper turn, as the turn's own record saw it.

    The Keeper's assigned lane is a different value: in-turn failover can
    answer on another candidate, and a turn that failed before any candidate
    answered has no answerer at all. Every metric that asks "which runtime
    answered this turn?" reads this closed sum, so a turn with no answerer
    carries one label everywhere instead of each metric inventing its own
    (#38570).

    Lives in [masc_types] so both the keeper metrics snapshot (library
    [masc]) and the model inference metrics parser
    ([masc.model_inference_metrics]) name the same value. *)

type t =
  | Executed of string
      (** The runtime id of the candidate that answered. *)
  | Not_observed
      (** The turn carried no answering runtime. Never filled in with the
          assigned lane. *)

(** Label rendering: the runtime id, or ["unobserved"]. *)
val to_label : t -> string
