(** Tells roster readers which Keepers' rows a Candle ledger append moved
    (RFC-0481 §3.2). A row shows the Keeper's portrait, and to an operator its
    balance and account revision, all read from the ledger. The ledger library
    knows neither Keepers' rows nor SSE, so the server installs its append
    observer here. A moved half-life sends
    {!Keeper_row_broadcast.roster_changed}; otherwise each touched Keeper gets
    {!Keeper_row_broadcast.changed}. *)

val announce : base_path:string -> Candle_event.t list -> unit

val install : unit -> unit
