type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let complete ?override ~sw ~net ?clock ~config ~messages () =
  match override with
  | Some complete -> complete ~sw ~net ?clock ~config ~messages ()
  | None ->
    Llm_provider.Complete.complete
      ~sw
      ~net
      ?clock
      ?body_timeout_s:(Keeper_runtime_resolved.body_timeout_override_sec ())
      ~config
      ~messages
      ()
;;
