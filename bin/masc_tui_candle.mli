(** Exact presentation of server-observed Candle amounts. No client arithmetic
    reconstructs a wallet or supply from the visible Keeper subset. *)
val amount_text : string -> string
val summary_lines : (Candle_observation.t, string) result option -> string list
val compact_status : (Candle_observation.t, string) result option -> string option
(** A typed reading status for a crowded Overview. Full reasons and exact
    supply amounts remain available in the global help sheet and Keeper Info.
    Off adds no status. *)
val balance_text : (Candle_observation.t, string) result option -> string option -> string option
