(** Autonomy_exec — external execution primitive for autonomy loops.

    This module is intentionally orchestration-agnostic. Consumers supply
    the command argv, timeout, and optional sandbox/container wrapper.

    @since 0.92.1 *)

type backend =
  | Direct
  | Argv_prefix of string list

type kill_scope =
  | Single_process
  | Process_group

type config =
  { backend : backend
  ; cwd : string option
  ; env_allowlist : string list
  ; extra_env : (string * string) list
  ; stdout_limit_bytes : int
  ; stderr_limit_bytes : int
  ; kill_scope : kill_scope
  }

let default_env_allowlist = [ "PATH"; "HOME"; "TMPDIR"; "LANG"; "LC_ALL"; "LC_CTYPE" ]

let default_config =
  { backend = Direct
  ; cwd = None
  ; env_allowlist = default_env_allowlist
  ; extra_env = []
  ; stdout_limit_bytes = 256 * 1024
  ; stderr_limit_bytes = 64 * 1024
  ; kill_scope = Single_process
  }
;;

type exit_status =
  | Exit_code of int
  | Exit_signal of int
  | Timed_out of int option

type output =
  { effective_argv : string list
  ; status : exit_status
  ; stdout : string
  ; stderr : string
  ; stdout_truncated : bool
  ; stderr_truncated : bool
  ; elapsed_s : float
  }

type capture =
  { text : string
  ; truncated : bool
  }

open Result_syntax

let argv_to_string argv = String.concat " " (List.map Filename.quote argv)

let status_to_string = function
  | Exit_code code -> Printf.sprintf "exit(%d)" code
  | Exit_signal signal -> Printf.sprintf "signal(%d)" signal
  | Timed_out None -> "timed_out"
  | Timed_out (Some signal) -> Printf.sprintf "timed_out(signal=%d)" signal
;;

let invalid_config field detail = Error.Config (Error.InvalidConfig { field; detail })
let file_op_error ~op ~path ~detail = Error.Io (Error.FileOpFailed { op; path; detail })

let validate_config config argv =
  match argv with
  | [] -> Error (invalid_config "argv" "command argv must not be empty")
  | _ when config.stdout_limit_bytes <= 0 ->
    Error (invalid_config "stdout_limit_bytes" "must be > 0")
  | _ when config.stderr_limit_bytes <= 0 ->
    Error (invalid_config "stderr_limit_bytes" "must be > 0")
  | _ when config.kill_scope = Process_group && config.backend = Direct ->
    Error
      (invalid_config
         "kill_scope"
         "Process_group requires an Argv_prefix wrapper that creates a dedicated process \
          group")
  | _ ->
    (match config.backend with
     | Argv_prefix [] ->
       Error (invalid_config "backend" "Argv_prefix wrapper must not be empty")
     | _ -> Ok ())
;;

let effective_argv ~config ~argv =
  let* () = validate_config config argv in
  let cwd_wrapper =
    match config.cwd with
    | None -> []
    | Some cwd when String.trim cwd = "" -> []
    | Some cwd -> [ "/usr/bin/env"; "-C"; cwd ]
  in
  let prefix =
    match config.backend with
    | Direct -> []
    | Argv_prefix items -> items
  in
  Ok (prefix @ cwd_wrapper @ argv)
;;

let split_env_entry entry =
  match String.index_opt entry '=' with
  | None -> None
  | Some idx ->
    let key = String.sub entry 0 idx in
    let value = String.sub entry (idx + 1) (String.length entry - idx - 1) in
    Some (key, value)
;;

let build_env ~config =
  let table = Hashtbl.create 16 in
  let allow key = List.mem key config.env_allowlist in
  Array.iter
    (fun entry ->
       match split_env_entry entry with
       | Some (key, value) when allow key -> Hashtbl.replace table key value
       | _ -> ())
    (Unix.environment ());
  List.iter (fun (key, value) -> Hashtbl.replace table key value) config.extra_env;
  Hashtbl.to_seq table
  |> List.of_seq
  |> List.sort (fun (ka, _) (kb, _) -> String.compare ka kb)
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> Array.of_list
;;

let status_of_unix_status = function
  | Unix.WEXITED code -> Exit_code code
  | Unix.WSIGNALED signal -> Exit_signal signal
  | Unix.WSTOPPED signal -> Exit_signal signal
;;

let drain_fd ~limit fd =
  let buf = Bytes.create 4096 in
  let out = Buffer.create (min limit 4096) in
  let truncated = ref false in
  let rec loop () =
    try
      match Unix.read fd buf 0 (Bytes.length buf) with
      | 0 -> ()
      | read ->
        let remaining = limit - Buffer.length out in
        if remaining > 0
        then (
          let keep = min read remaining in
          Buffer.add_string out (Bytes.sub_string buf 0 keep);
          if keep < read then truncated := true)
        else truncated := true;
        loop ()
    with
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
      Eio_unix.await_readable fd;
      loop ()
  in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close fd with
      | Unix.Unix_error _ -> ())
    (fun () ->
       loop ();
       { text = Buffer.contents out; truncated = !truncated })
;;

let kill_child config pid =
  let target =
    match config.kill_scope with
    | Single_process -> pid
    | Process_group -> -pid
  in
  try Unix.kill target Sys.sigkill with
  | Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ()
;;

let spawn_child config effective =
  let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let stdout_r, stdout_w = Unix.pipe () in
  let stderr_r, stderr_w = Unix.pipe () in
  let close_quietly fd =
    try Unix.close fd with
    | Unix.Unix_error _ -> ()
  in
  try
    Unix.set_nonblock stdout_r;
    Unix.set_nonblock stderr_r;
    let env = build_env ~config in
    let exec = List.hd effective in
    let pid =
      Unix.create_process_env
        exec
        (Array.of_list effective)
        env
        stdin_fd
        stdout_w
        stderr_w
    in
    close_quietly stdin_fd;
    close_quietly stdout_w;
    close_quietly stderr_w;
    Ok (pid, stdout_r, stderr_r)
  with
  | Unix.Unix_error (err, fn, arg) ->
    close_quietly stdin_fd;
    close_quietly stdout_r;
    close_quietly stdout_w;
    close_quietly stderr_r;
    close_quietly stderr_w;
    Error
      (file_op_error
         ~op:"spawn"
         ~path:(argv_to_string effective)
         ~detail:(Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err)))
;;

let spawn_result_promise ~sw fn =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      try Ok (fn ()) with
      | exn -> Error exn
    in
    Eio.Promise.resolve resolver result);
  promise
;;

let await_result promise map_exn =
  match Eio.Promise.await promise with
  | Ok value -> Ok value
  | Error (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | Error exn -> Error (map_exn exn)
;;

let run ~sw ~clock ~config ~argv ~timeout_s =
  let t0 = Unix.gettimeofday () in
  let* effective = effective_argv ~config ~argv in
  let* pid, stdout_r, stderr_r = spawn_child config effective in
  let close_quietly fd =
    try Unix.close fd with
    | Unix.Unix_error _ -> ()
  in
  let stdout_reader_started = ref false in
  let stderr_reader_started = ref false in
  let completed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !completed
      then (
        kill_child config pid;
        if not !stdout_reader_started then close_quietly stdout_r;
        if not !stderr_reader_started then close_quietly stderr_r))
    (fun () ->
       let wait_promise =
         spawn_result_promise ~sw (fun () ->
           Eio_unix.run_in_systhread ~label:"autonomy-exec-waitpid" (fun () ->
             snd (Unix.waitpid [] pid)))
       in
       stdout_reader_started := true;
       let stdout_promise =
         spawn_result_promise ~sw (fun () ->
           drain_fd ~limit:config.stdout_limit_bytes stdout_r)
       in
       stderr_reader_started := true;
       let stderr_promise =
         spawn_result_promise ~sw (fun () ->
           drain_fd ~limit:config.stderr_limit_bytes stderr_r)
       in
       let capture_and_finish status =
         let* stdout_capture =
           await_result stdout_promise (fun exn ->
             file_op_error ~op:"read" ~path:"stdout" ~detail:(Printexc.to_string exn))
         in
         let* stderr_capture =
           await_result stderr_promise (fun exn ->
             file_op_error ~op:"read" ~path:"stderr" ~detail:(Printexc.to_string exn))
         in
         Ok
           { effective_argv = effective
           ; status
           ; stdout = stdout_capture.text
           ; stderr = stderr_capture.text
           ; stdout_truncated = stdout_capture.truncated
           ; stderr_truncated = stderr_capture.truncated
           ; elapsed_s = Unix.gettimeofday () -. t0
           }
       in
       try
         let* unix_status =
           Eio.Time.with_timeout_exn clock timeout_s (fun () ->
             await_result wait_promise (fun exn ->
               file_op_error
                 ~op:"waitpid"
                 ~path:(string_of_int pid)
                 ~detail:(Printexc.to_string exn)))
         in
         let result = capture_and_finish (status_of_unix_status unix_status) in
         completed := true;
         result
       with
       | Eio.Time.Timeout ->
         kill_child config pid;
         let timed_out_signal =
           match
             await_result wait_promise (fun exn ->
               file_op_error
                 ~op:"waitpid"
                 ~path:(string_of_int pid)
                 ~detail:(Printexc.to_string exn))
           with
           | Ok (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> Some signal
           | Ok (Unix.WEXITED _) -> None
           | Error _ -> None
         in
         let result = capture_and_finish (Timed_out timed_out_signal) in
         completed := true;
         result
       | Eio.Cancel.Cancelled _ as exn -> raise exn)
;;

[@@@coverage off]
(* === Inline tests === *)

let with_eio f =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~sw ~clock:env#clock
;;

let%test "effective_argv direct preserves argv" =
  match effective_argv ~config:default_config ~argv:[ "cmd"; "--flag" ] with
  | Ok argv -> argv = [ "cmd"; "--flag" ]
  | Error _ -> false
;;

let%test "effective_argv adds cwd wrapper and backend prefix" =
  let config =
    { default_config with
      backend = Argv_prefix [ "docker"; "run"; "--rm" ]
    ; cwd = Some "/tmp/work"
    }
  in
  match effective_argv ~config ~argv:[ "tool"; "arg" ] with
  | Ok argv ->
    argv = [ "docker"; "run"; "--rm"; "/usr/bin/env"; "-C"; "/tmp/work"; "tool"; "arg" ]
  | Error _ -> false
;;

let%test "effective_argv rejects process group without wrapper" =
  let config = { default_config with kill_scope = Process_group } in
  match effective_argv ~config ~argv:[ "cmd" ] with
  | Error (Error.Config (Error.InvalidConfig { field = "kill_scope"; _ })) -> true
  | _ -> false
;;

let%test "build_env keeps allowlisted variables and overrides" =
  Unix.putenv "AUTONOMY_EXEC_TEST_KEEP" "keep";
  Unix.putenv "AUTONOMY_EXEC_TEST_DROP" "drop";
  let env =
    build_env
      ~config:
        { default_config with
          env_allowlist = [ "AUTONOMY_EXEC_TEST_KEEP" ]
        ; extra_env = [ "AUTONOMY_EXEC_TEST_KEEP", "override"; "EXTRA_ONLY", "yes" ]
        }
    |> Array.to_list
  in
  List.mem "AUTONOMY_EXEC_TEST_KEEP=override" env
  && List.mem "EXTRA_ONLY=yes" env
  && not
       (List.exists
          (fun s ->
             Util.contains_substring_ci ~haystack:s ~needle:"AUTONOMY_EXEC_TEST_DROP")
          env)
;;

let%test_unit "run captures stdout and stderr" =
  with_eio
  @@ fun ~sw ~clock ->
  let result =
    run
      ~sw
      ~clock
      ~config:default_config
      ~argv:
        [ "/usr/bin/env"
        ; "python3"
        ; "-c"
        ; "import sys; sys.stdout.write('ok'); sys.stderr.write('err')"
        ]
      ~timeout_s:2.0
  in
  match result with
  | Ok output ->
    assert (output.stdout = "ok");
    assert (output.stderr = "err");
    assert (output.status = Exit_code 0)
  | Error err -> failwith (Error.to_string err)
;;

let%test_unit "run times out and returns Timed_out" =
  with_eio
  @@ fun ~sw ~clock ->
  let result =
    run
      ~sw
      ~clock
      ~config:default_config
      ~argv:[ "/usr/bin/env"; "python3"; "-c"; "import time; time.sleep(5)" ]
      ~timeout_s:0.1
  in
  match result with
  | Ok output ->
    (match output.status with
     | Timed_out _ -> ()
     | status -> failwith ("expected timeout, got " ^ status_to_string status))
  | Error err -> failwith (Error.to_string err)
;;

let%test_unit "run preserves switch cancellation" =
  with_eio
  @@ fun ~sw:_ ~clock ->
  let run_outcome = ref None in
  (try
     Eio.Switch.run
     @@ fun child_sw ->
     Eio.Fiber.fork ~sw:child_sw (fun () ->
       Eio.Time.sleep clock 0.05;
       Eio.Switch.fail child_sw Exit);
     run_outcome
     := Some
          (try
             match
               run
                 ~sw:child_sw
                 ~clock
                 ~config:default_config
                 ~argv:[ "/usr/bin/env"; "python3"; "-c"; "import time; time.sleep(0.5)" ]
                 ~timeout_s:0.2
             with
             | Ok _ -> `Returned_ok
             | Error err -> `Returned_error (Error.to_string err)
           with
           | Eio.Cancel.Cancelled _ -> `Cancelled
           | exn -> `Raised (Printexc.to_string exn))
   with
   | Exit -> ());
  match !run_outcome with
  | Some `Cancelled -> ()
  | Some `Returned_ok -> failwith "expected switch cancellation, got normal return"
  | Some (`Returned_error err) ->
    failwith ("expected switch cancellation, got error: " ^ err)
  | Some (`Raised exn) -> failwith ("expected switch cancellation, got exception: " ^ exn)
  | None -> failwith "run outcome was not recorded before switch failure"
;;
