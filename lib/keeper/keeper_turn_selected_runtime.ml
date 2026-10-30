type attempt_end =
  | Completed of
      { runtime_id : string
      ; selected_model : string option
      }
  | Failed of
      { answering_runtime_id : string option
      ; terminal_origin_runtime_id : string option
      }

let selected_runtime = function
  | Completed { runtime_id; selected_model } ->
    Some { Keeper_registry_types.sr_runtime_id = runtime_id; sr_model = selected_model }
  | Failed { answering_runtime_id = Some runtime_id; terminal_origin_runtime_id = _ }
  | Failed
      { answering_runtime_id = None; terminal_origin_runtime_id = Some runtime_id } ->
    Some { Keeper_registry_types.sr_runtime_id = runtime_id; sr_model = None }
  | Failed { answering_runtime_id = None; terminal_origin_runtime_id = None } -> None
;;
