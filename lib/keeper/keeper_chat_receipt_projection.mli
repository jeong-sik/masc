(** Canonical external projection of one Keeper chat queue receipt.

    Queue persistence has a separate private wire format.  HTTP, dashboard,
    and operator tools use this projection so revision and state semantics
    cannot drift between surfaces. *)

val state_json : Keeper_chat_queue.receipt_state -> Yojson.Safe.t

val receipt_json :
  keeper_name:string ->
  revision:int64 ->
  Keeper_chat_queue.receipt_view ->
  Yojson.Safe.t
