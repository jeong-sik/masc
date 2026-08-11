# task-238 bounded identity timeout evidence

Source: `lib/keeper/keeper_github_identity.ml`
Commit: `aaff0e753eea072f2ad1eae402335c6999686bed`

```ocaml
let github_probe_timeout_sec = 15.0
let github_interactive_timeout_sec = 600.0
let interactive_timeout_sec = github_interactive_timeout_sec

let validate_timeout_sec timeout_sec =
  if Float.is_finite timeout_sec && Float.compare timeout_sec 0.0 > 0
  then timeout_sec
  else
    invalid_arg
      (Printf.sprintf
         "GitHub CLI timeout must be finite and greater than zero (got %g)"
         timeout_sec)
;;

let run_capture ?(timeout_sec = github_probe_timeout_sec) ~env = function
  | [] -> Unix.WEXITED 127, "", "GitHub CLI argv must not be empty"
  | argv ->
    Process_eio.run_argv_with_status_split
      ~timeout_sec:(validate_timeout_sec timeout_sec)
      ~env
      argv
;;

let run_inherited ?(timeout_sec = interactive_timeout_sec) ~env = function
  | [] -> Unix.WEXITED 127
  | command :: _ as argv ->
    let timeout_sec = validate_timeout_sec timeout_sec in
    let waitpid_blocking pid =
      let rec wait () =
        try snd (Unix.waitpid [] pid) with
        | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        | Unix.Unix_error (Unix.ECHILD, _, _) -> Unix.WEXITED 127
      in
      wait ()
    in
    let terminate_and_reap pid =
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      waitpid_blocking pid
    in
    let wait_with_timeout pid =
      let deadline = Unix.gettimeofday () +. timeout_sec in
      let rec wait () =
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ when Unix.gettimeofday () >= deadline ->
          ignore (terminate_and_reap pid);
          Unix.WEXITED 124
        | 0, _ ->
          ignore
            (Unix.select [] [] []
               (min 0.05 (deadline -. Unix.gettimeofday ())));
          wait ()
        | _, status -> status
      in
      wait ()
    in
    (try
       let process =
         Unix.create_process_env
           command
           (Array.of_list argv)
           env
           Unix.stdin
           Unix.stdout
           Unix.stderr
       in
       (try wait_with_timeout process with
        | Eio.Cancel.Cancelled _ as exn ->
          ignore (terminate_and_reap process);
          raise exn)
     with
     | Unix.Unix_error (error, operation, target) ->
       prerr_endline
         (Printf.sprintf
            "cannot run GitHub CLI: %s(%s): %s"
            operation
            target
            (Unix.error_message error));
       Unix.WEXITED 127)
;;
```

The omitted body is unchanged process setup/error plumbing; the bounded wait and kill/reap path above is the changed behavior required by the task.
