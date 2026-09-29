(** Exact presentation of server-observed Candle amounts. No client arithmetic
    reconstructs a wallet or supply from the visible Keeper subset. *)
val amount_text : string -> string
val summary_lines : (Candle_observation.t, string) result option -> string list
val balance_text : (Candle_observation.t, string) result option -> string option -> string option
