(** A reading of a turn's spend, as its raw cost row records it.

    An execution observes each reading through {!Keeper_turn_spend} and writes
    a raw cost row beside it. The row's counts alone cannot be observed again:
    they do not say whether the reading was an Agent Core response or an
    official client's report, whether the provider reported a cost, or whether
    a client report replaced its count. The row carries the observation itself
    under {!field}, so a reader hands {!Keeper_turn_spend} exactly what the
    execution handed it. *)

type t =
  | Agent_core_response of
      { response_id : string
      ; ordinal : int
      ; model : string
      ; usage : Keeper_usage_resolution.sample option
            (** [None]: the response carried no usage. *)
      }
  | Client_report of Keeper_client_usage_report.t

(** The raw cost row field that holds the observation. *)
val field : string

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** Observe the reading into the spend's current attempt, as the execution
    did when it read it. *)
val observe : Keeper_turn_spend.t -> t -> (Keeper_turn_spend.t, Keeper_turn_spend.unplaced) result
