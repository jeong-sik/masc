type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_core.Types.message list ->
  ?tools:Yojson.Safe.t list ->
  unit ->
  (Agent_core.Types.api_response, Llm_provider.Http_client.http_error) result

let complete ?override ~sw ~net ?clock ~config ~messages ?tools () =
  match override with
  | Some complete -> complete ~sw ~net ?clock ~config ~messages ?tools ()
  | None ->
    Llm_provider.Complete.complete
      ~sw
      ~net
      ?clock
      ?body_timeout_s:(Keeper_runtime_resolved.body_timeout_override_sec ())
      ~config
      ~messages
      ?tools
      ()
;;
