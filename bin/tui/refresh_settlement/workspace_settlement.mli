(** Workspace/detail reading revocation, Keeper chat settlement, and currency authority. *)

val apply_keeper_chat_result
  :  Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> ( Masc_tui_keeper_chat_projection.response
     , Masc_tui_keeper_chat_projection.error )
     result
  -> bool

val revoke_detail_readings : Masc_tui_types.state -> unit

val same_currency_workspace
  :  Masc.Tui_decode.server_identity option
  -> Masc.Tui_decode.server_identity option
  -> bool

val withdraw_currency_authority : Masc_tui_types.state -> unit
