type t = Agent_core.Agent.execution_runtime

type install_error = Already_installed

type availability =
  | Available of t
  | Unavailable

let installed_owner : t option Atomic.t = Atomic.make None

let create ~sw ~domain_mgr ~domain_count =
  Agent_core.Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count
;;

let install ~sw owner =
  let installed = Some owner in
  if Atomic.compare_and_set installed_owner None installed
  then begin
    Eio.Switch.on_release sw (fun () ->
      ignore (Atomic.compare_and_set installed_owner installed None));
    Ok ()
  end
  else Error Already_installed
;;

let current () =
  match Atomic.get installed_owner with
  | Some owner -> Available owner
  | None -> Unavailable
;;

let execution_runtime owner = owner
