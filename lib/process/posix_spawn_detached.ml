external posix_spawn
  :  string
  -> string array
  -> string array
  -> (string option * bool)
  -> (int * Unix.file_descr) list
  -> int
  = "masc_posix_spawn"

type t = { pid : int; exited : Unix.process_status option Eio.Promise.t }

let rec reaped pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some (Some status)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reaped pid
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some None

let spawn ~sw ~argv ~env ~output =
  match argv with
  | [] -> Error "posix_spawn: empty argv"
  | executable :: _ ->
    (* Only a backend that installs a SIGCHLD handler broadcasts the
       condition [reaped] waits on (see Posix_spawn_process_mgr). *)
    Eio_unix.Process.install_sigchld_handler ();
    (match Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
     | exception Unix.Unix_error (code, _, _) ->
       Error ("cannot open /dev/null: " ^ Unix.error_message code)
     | devnull ->
       let started =
         Fun.protect
           ~finally:(fun () -> Unix.close devnull)
           (fun () ->
             match
               posix_spawn executable (Array.of_list argv) env (None, true)
                 [ 0, devnull; 1, output; 2, output ]
             with
             | pid -> Ok pid
             | exception Unix.Unix_error (code, _, _) ->
               Error (Printf.sprintf "posix_spawn %s: %s" executable (Unix.error_message code)))
       in
       Result.map
         (fun pid ->
           let exited, set_exited = Eio.Promise.create () in
           Eio.Fiber.fork_daemon ~sw (fun () ->
             Eio.Promise.resolve set_exited
               (Eio.Condition.loop_no_mutex Eio_unix.Process.sigchld (fun () -> reaped pid));
             `Stop_daemon);
           { pid; exited })
         started)
