module Outbox = Keeper_client_tool_outbox
module Session_store = Keeper_official_client_session_store

let load ~superseded run =
  match superseded with
  | Session_store.Not_superseding_input_rejection -> Outbox.run_carrier_load run
  | Session_store.Superseding_effect_fenced
  | Session_store.Superseding_bootstrap_floor_exceeded ->
    Outbox.run_carrier_load_by_address run
;;
