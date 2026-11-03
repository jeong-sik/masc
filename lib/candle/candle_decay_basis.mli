(** What a Candle read folds the ledger to before it decays the balances to
    the read time (RFC-0481 §3.7).

    A reader that holds it computes each Keeper's balance, and the burned and
    circulating supply, at a later instant with {!Candle_decay.remaining}. The
    result is what {!Candle_balance.of_events} folds from the same ledger at
    that instant: the same function on the same inputs. Pure: no clock, file
    or global state. *)

type keeper = { since : Candle_time.t; amount_milli : int }
(** A Keeper's last balance event and its balance right after it. *)

type decay =
  | No_decaying_balance  (** No Keeper has a balance event. *)
  | Decaying of { half_life : Candle_decay.half_life; keepers : (string * keeper) list }
      (** [keepers] is in name order, one entry per name. *)

type t = { issued_milli : Z.t; burned_milli : Z.t; decay : decay }
(** [burned_milli] is the burned supply through each Keeper's last balance
    event, before the decay to the read time. *)

val of_events : Candle_event.t list -> (t, Candle_balance.error) result
(** [Error Missing_half_life] when a Keeper has a balance event and the ledger
    records no half-life, which {!Candle_balance.of_events} refuses too. *)

val balance_at : t -> keeper:string -> at:Candle_time.t -> (int, Candle_decay.error) result
(** 0 for a Keeper with no balance event. [Error Reversed_interval] when [at]
    is before the Keeper's last balance event. *)

val supply_at : t -> at:Candle_time.t -> (Candle_balance.supply, Candle_decay.error) result
(** Issued as recorded; burned is [burned_milli] plus what every balance lost
    from its last balance event to [at]; circulating is issued minus burned. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict: amounts are canonical decimal strings, a half-life comes with at
    least one Keeper and the other way round, Keeper names are in order and
    unique, and an unknown field is refused. *)
