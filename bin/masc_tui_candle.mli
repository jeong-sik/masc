(** Candle amounts as the server folds them at the moment they are drawn
    (RFC-0481 §3.7). The roster carries the fold's basis, and each balance and
    the supply are computed from it with {!Candle_decay_basis}, the server's
    own function, at [now] (Unix seconds). *)

val amount_text : string -> string

val summary_lines : now:float -> (Masc.Tui_decode.candle_reading, string) result option -> string list

val compact_status : (Masc.Tui_decode.candle_reading, string) result option -> string option
(** A typed reading status for a crowded Overview. Full reasons and exact
    supply amounts remain available in the global help sheet and Keeper Info.
    Off adds no status. *)

val balance_text :
  now:float -> (Masc.Tui_decode.candle_reading, string) result option -> keeper:string -> string option

val balance_milli :
  now:float -> (Masc.Tui_decode.candle_reading, string) result option -> keeper:string -> int option
(** The Keeper's balance at [now] when the roster's Candle is ready. *)

val keeper_basis :
  (Masc.Tui_decode.candle_reading, string) result option -> keeper:string -> Candle_decay_basis.keeper option
(** The Keeper's last balance event and amount. It changes only when the
    ledger does, so the Items tab watches it rather than a balance that falls
    with time. *)
