type error = Owner_not_ready | Workspace_mismatch | Configuration_unavailable
type owner = { base_path : string; resume : unit -> (bool, error) result; lock : Eio.Mutex.t }
let owner : owner option Atomic.t = Atomic.make None
let error_message = function
  | Owner_not_ready -> "The workspace owner has not finished preparing model setup. Retry shortly."
  | Workspace_mismatch -> "Model setup resume belongs to another workspace."
  | Configuration_unavailable -> "The saved model connection is not ready. Review connection settings and retry."
let install ~sw ~base_path ~resume =
  let installed = Some {base_path;resume;lock=Eio.Mutex.create ()} in
  if not (Atomic.compare_and_set owner None installed) then
    invalid_arg "model setup resume already has an owner";
  (* fire-and-forget: the release clears the owner only when this install
     still owns it; a later install's compare_and_set already replaced it. *)
  Eio.Switch.on_release sw (fun () -> ignore (Atomic.compare_and_set owner installed None))
let request ~base_path =
  match Atomic.get owner with
  | None -> Error Owner_not_ready
  | Some active when active.base_path <> base_path -> Error Workspace_mismatch
  | Some active -> Eio.Mutex.use_rw ~protect:true active.lock active.resume
