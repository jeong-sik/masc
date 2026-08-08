(** Minimal background task wrapper with a waitpid reaper. *)

type t = {
  handle : Process_eio.detached_handle;
  watcher : Thread.t;
}

let handle t = t.handle

let start_reaper (handle : Process_eio.detached_handle) =
  Thread.create
    (fun () ->
       let rec wait () =
         match Unix.waitpid [] handle.pid with
         | _, _ -> ()
         | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
         | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
         | exception _ -> ()
       in
       wait ())
    ()

let spawn ~argv ~env ~cwd =
  match Process_eio.spawn_detached ~argv ~env ~cwd with
  | Error msg -> Error msg
  | Ok handle ->
      let watcher = start_reaper handle in
      Ok { handle; watcher }

let kill t ~signal ~grace_sec =
  Process_eio.tree_kill ~pgid:t.handle.pgid ~signal ~grace_sec

let is_alive t = Process_eio.is_pgid_alive ~pgid:t.handle.pgid
