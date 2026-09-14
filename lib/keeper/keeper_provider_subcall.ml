type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_core.Types.message list ->
  ?tools:Yojson.Safe.t list ->
  unit ->
  (Agent_core.Types.api_response, Llm_provider.Http_client.http_error) result

(* A non-streaming call shows no progress until it completes, and a call made
   from inside a tool is outside the attempt watchdog's view
   ([Keeper_turn_driver_try_provider.attempt_stalled] exempts a tool in
   flight), so this boundary bounds the call itself. The keeper's no-progress
   threshold bounds the whole call, the wait for the binding's admission
   permit included: a call queued behind another keeper's stream makes no
   progress either. A declared body deadline bounds the round trip inside
   it, so the narrower of the two fires and names its own setting. With
   neither declared the call has no bound (#36020). *)
let complete ?override ~sw ~net ~clock ~config ~messages ?tools () =
  match override with
  | Some complete -> complete ~sw ~net ~clock ~config ~messages ?tools ()
  | None ->
    Llm_provider.Complete.complete
      ~sw
      ~net
      ~clock
      ?body_timeout_s:(Keeper_runtime_resolved.body_timeout_override_sec ())
      ?call_timeout_s:(Keeper_runtime_resolved.provider_call_deadline_sec ())
      ~config
      ~messages
      ?tools
      ()
;;
