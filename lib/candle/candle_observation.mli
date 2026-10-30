(** Read-only currency observations. Decimal strings preserve exact amounts
    across native and JavaScript consumers. *)
type t =
  | Off
  | Disabled of { reason : string }
  | Ready of Candle_balance.supply

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val amount_of_json : Yojson.Safe.t -> (string, string) result
val balance_of_json : Yojson.Safe.t -> (string option, string) result
