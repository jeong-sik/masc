(** Durable TUI-side fence for a Keeper chat whose terminal outcome has not
    yet been observed. *)

type request = Masc_tui_keeper_chat_projection.request

val recovery_path : base_path:string -> string
val persist_pending : base_path:string -> request -> (unit, string) result
val load_pending : base_path:string -> (request option, string) result
val clear_pending : base_path:string -> request -> (unit, string) result

val max_reconciliation_polls : int
val next_reconciliation_poll : remaining:int -> [ `Poll of int | `Stop ]
