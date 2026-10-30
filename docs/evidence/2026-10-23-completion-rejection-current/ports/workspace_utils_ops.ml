type lease_commit_refusal = Lease_lost
let lease_commit_refusal_to_string = function Lease_lost -> "injected lease lost"
let with_file_lock_r (config:Workspace_utils_backend_setup.config) path use =
  if path <> "explicit-backlog-lock-port" then failwith "unexpected lock key";
  match config.lock_failure with
  | Some error -> Error error
  | None ->
    if config.lock_held then failwith "recursive backlog lock";
    (match config.before_lock with
     | None -> ()
     | Some interpose -> config.before_lock <- None; interpose ());
    config.lock_held <- true;
    Fun.protect ~finally:(fun () -> config.lock_held <- false)
      (fun () -> Ok (use ()))
let commit_under_held_lease (config:Workspace_utils_backend_setup.config) path use =
  if path <> "explicit-backlog-lock-port" || not config.lock_held
  then failwith "fence without the owning backlog lock";
  (match config.before_fence with
   | None -> ()
   | Some interpose -> config.before_fence <- None; interpose ());
  if config.lease_lost then Error Lease_lost
  else begin
    if config.fence_held then failwith "recursive lease fence";
    config.fence_held <- true;
    Fun.protect ~finally:(fun () -> config.fence_held <- false)
      (fun () -> Ok (use ()))
  end
