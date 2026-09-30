(** Pure operator-facing wire projection of Keeper questions.
    Kept separate from HTTP, persistence and answer delivery. *)

val ask_row_is_open : Keeper_ask.resolution -> bool

val ask_row_json :
  keeper_name:string ->
  string * (Keeper_ask.ask * Keeper_ask.resolution) -> Yojson.Safe.t
(** Encode the published question and its resolution. Choice identities are
    retained; every question offers the operator a free-text alternative. *)
