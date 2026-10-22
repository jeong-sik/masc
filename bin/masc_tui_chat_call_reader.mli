(** Read-only selection of original transcript executions; never a recent-call search. *)
type choice = { execution_id : string; tool : string; args : string; subject : string option }
type t
type request = string Masc_tui_fetched.request
val path : keeper:string -> execution_id:string -> string
type action = Close | Choose of int | Open | Retry | Move of Masc_tui_detail_reading.movement | Ignore
val action : key:string -> height:int -> t -> action
val create : choice list -> t
val choices : t -> choice list
val selected : t -> choice option
val choosing : t -> bool
val choose : int -> t -> t
val select_execution : string -> t -> t option
val start : t -> t * request option
val complete : t -> request -> (Masc.Tui_decode.keeper_call, string) result -> t
val back : t -> t
val document : t -> Masc_tui_detail_reading.t
val move : count:int -> height:int -> Masc_tui_detail_reading.movement -> t -> t
val search_key : width:int -> height:int -> key:string -> t -> t option
val search_insert : width:int -> height:int -> text:string -> t -> t
(** Search belongs to the captured document. Choosing another execution or
    returning to the chooser creates a fresh document and clears its query. *)
val observation : t -> Masc.Tui_decode.keeper_call Masc_tui_fetched.view
val pending : t -> bool
