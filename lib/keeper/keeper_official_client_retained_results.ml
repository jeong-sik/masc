module Outbox = Keeper_client_tool_outbox
module Session_store = Keeper_official_client_session_store
module Reprojection = Keeper_memory_delivery_reprojection

let load ~keeper_name ~superseded run =
  match Outbox.run_carrier_load run with
  | Error _ as error -> error
  | Ok ((_, carrier) as loaded) ->
    (match superseded with
     | Session_store.Supersedes_no_size_refusal -> ()
     | Session_store.Supersedes_size_refusal ->
       (match Outbox.switch_to_address carrier with
        | Ok (Reprojection.Reprojected | Reprojection.Unchanged) -> ()
        | Error detail ->
          Log.Keeper.warn
            ~keeper_name
            "retained results stay inline in the run after a size refusal: they could \
             not switch to the address form: %s"
            detail));
    Ok loaded
;;
