type initialization_error =
  | Already_initialized
  | Core_initialization_failed of Agent_core.Error.t

let current : Agent_core.Agent.execution_runtime option Atomic.t = Atomic.make None

let initialization_error_to_string = function
  | Already_initialized -> "native execution runtime already has a process owner"
  | Core_initialization_failed error -> Agent_core.Error.to_string error

let initialize ~sw ~domain_mgr ~domain_count =
  match Atomic.get current with
  | Some _ -> Error Already_initialized
  | None ->
    (match Agent_core.Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count with
     | Error error -> Error (Core_initialization_failed error)
     | Ok runtime ->
       let installed = Some runtime in
       if Atomic.compare_and_set current None installed then (
         Eio.Switch.on_release sw (fun () ->
           ignore (Atomic.compare_and_set current installed None : bool));
         Ok ())
       else Error Already_initialized)

let get () = Atomic.get current
