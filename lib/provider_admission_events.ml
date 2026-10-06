let wire_name = "masc.provider_admission.waited"

let outcome_to_string : Llm_provider.Provider_admission.wait_outcome -> string = function
  | Wait_granted -> "granted"
  | Wait_expired -> "expired"
;;

let optional_string = function
  | Some value -> `String value
  | None -> `Null
;;

let optional_float = function
  | Some value -> `Float value
  | None -> `Null
;;

let event (wait : Llm_provider.Provider_admission.wait) =
  Agent_core.Event_bus.mk_event
    (Agent_core.Event_bus.Custom
       ( wire_name
       , `Assoc
           [ "provider_id", optional_string wait.provider_id
           ; "kind", `String wait.kind
           ; "model", `String wait.model_id
           ; ( "admission_class"
             , `String (Llm_provider.Admission_class.to_string wait.admission_class) )
           ; "waited_ms", optional_float wait.waited_ms
           ; "outcome", `String (outcome_to_string wait.outcome)
           ] ))
;;

let install ~sw bus =
  Llm_provider.Provider_admission.set_wait_observer
    (Some (fun wait -> Runtime_event_bus.publish bus (event wait)));
  Eio.Switch.on_release sw (fun () ->
    Llm_provider.Provider_admission.set_wait_observer None)
;;
