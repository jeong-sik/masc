(* The installer's Muse sign-in. The installer runs this instead of the official
   client, so the login child gets Runtime_muse_serve.login_environment: the
   selected HOME and XDG roots, the file credential backend, and none of the
   caller's provider credentials or backend overrides, the same as every Muse
   child the server starts. This process becomes the official client, so the
   exit status and the terminal's signals are the client's own. *)
let run ~cli_path ~account_home =
  match Runtime_account_home.of_string account_home with
  | Error detail ->
    prerr_endline ("Muse account home: " ^ detail);
    1
  | Ok account_home ->
    (try
       Unix.execve cli_path
         (Array.of_list (Runtime_muse_serve.login_argv ~cli_path))
         (Runtime_muse_serve.login_environment ~account_home)
     with Unix.Unix_error (error, _, _) ->
       prerr_endline
         ("Muse sign-in could not start " ^ cli_path ^ ": " ^ Unix.error_message error);
       1)
