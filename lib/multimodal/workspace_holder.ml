(* Workspace_holder — see workspace_holder.mli for design. *)

let mutex = Mutex.create ()

let workspace_ref = ref Workspace.empty

let get () =
  Mutex.lock mutex;
  let snap = !workspace_ref in
  Mutex.unlock mutex;
  snap

let replace ws =
  Mutex.lock mutex;
  workspace_ref := ws;
  Mutex.unlock mutex

let update f =
  Mutex.lock mutex;
  let next =
    try f !workspace_ref
    with exn ->
      Mutex.unlock mutex;
      raise exn
  in
  workspace_ref := next;
  Mutex.unlock mutex

let reset () = replace Workspace.empty
