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
   flight), so this boundary bounds the call itself. A declared body deadline
   is the narrower statement and wins; otherwise the keeper's own no-progress
   threshold applies to a call that by construction makes no progress until
   it ends. Neither declared is the operator's choice of no bound. *)
let deadline_s ~body_timeout_override_sec ~provider_call_deadline_sec =
  match body_timeout_override_sec with
  | Some seconds -> Some seconds
  | None -> provider_call_deadline_sec
;;

let resolved_deadline_s () =
  deadline_s
    ~body_timeout_override_sec:(Keeper_runtime_resolved.body_timeout_override_sec ())
    ~provider_call_deadline_sec:(Keeper_runtime_resolved.provider_call_deadline_sec ())
;;

let complete ?override ~sw ~net ~clock ~config ~messages ?tools () =
  match override with
  | Some complete -> complete ~sw ~net ~clock ~config ~messages ?tools ()
  | None ->
    Llm_provider.Complete.complete
      ~sw
      ~net
      ~clock
      ?body_timeout_s:(resolved_deadline_s ())
      ~config
      ~messages
      ?tools
      ()
;;
