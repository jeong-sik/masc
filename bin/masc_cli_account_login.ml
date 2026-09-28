(* The installer's sign-in for a Codex, Claude Code or Muse Code account home
   that runtime.toml already declares. The installer runs this instead of the
   official client, so the login child gets the environment /login gives that
   client (Runtime_setup_login_client). The client's exit code is this
   command's. *)

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

(* Ctrl-C at the terminal reaches the client, which owns the sign-in. A
   handler, unlike an ignore disposition, is not inherited across exec, so
   the client keeps its own default while this process waits for it. *)
let while_client_runs action =
  let previous = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> ())) in
  Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigint previous) action

let run ~client ~cli_path ~account_home =
  match Runtime_setup_login_client.selected_native client ~account_home with
  | Error detail ->
    prerr_endline ("Account home: " ^ detail);
    1
  | Ok login ->
    (match Runtime_setup_login_client.environment login with
     | Error detail ->
       prerr_endline ("Sign-in environment: " ^ detail);
       1
     | Ok environment ->
       let argv = Array.of_list (Runtime_setup_login_client.argv ~cli_path login) in
       let status = while_client_runs (fun () ->
         match Unix.create_process_env cli_path argv environment
                 Unix.stdin Unix.stdout Unix.stderr with
         | pid -> Ok (wait pid)
         | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)) in
       (match status with
        | Error detail ->
          prerr_endline ("Sign-in could not start " ^ cli_path ^ ": " ^ detail);
          1
        | Ok (Unix.WEXITED code) -> code
        | Ok (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 1))
