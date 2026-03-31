(** Async process execution helpers for Eio

    - argv-only APIs (no shell)
    - Global proc_mgr/clock initialized once from main_eio.ml

    This module is used by tool handlers where we want:
    - Non-blocking execution (Eio fibers)
    - Injection safety (no `sh -c`)
    - Consistent output capture (stdout only)
*)

(** ── Global state (initialized once from main_eio.ml) ──────────── *)

type runtime = {
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cwd_default : Eio.Fs.dir_ty Eio.Path.t;
}

let runtime_state : runtime option ref = ref None

let init ~cwd_default ~proc_mgr ~clock =
  runtime_state := Some { proc_mgr; clock; cwd_default }

let is_initialized () = Option.is_some !runtime_state

let reset_for_testing () =
  runtime_state := None

let get_proc_mgr () =
  match !runtime_state with
  | Some runtime -> Ok runtime.proc_mgr
  | None -> Error "Process_eio.get_proc_mgr: init not called"

let get_clock () =
  match !runtime_state with
  | Some runtime -> Ok runtime.clock
  | None -> Error "Process_eio.get_clock: init not called"

let get_cwd_default () =
  match !runtime_state with
  | Some runtime -> Ok runtime.cwd_default
  | None -> Error "Process_eio.get_cwd_default: init not called"

(** ── Unix fallback for tests (when Eio not initialized) ──────────── *)

let default_env = function
  | Some env -> env
  | None -> Unix.environment ()

let rec should_retry_unix_fallback = function
  | Unix.Unix_error
      ((Unix.EADDRINUSE | Unix.EADDRNOTAVAIL | Unix.EACCES | Unix.EPERM), "bind", _) ->
      true
  | Eio.Cancel.Cancelled exn -> should_retry_unix_fallback exn
  | _ -> false

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> () (* intentional: best-effort cleanup *)

let with_unix_capture ?env ?stdin_content (argv : string list)
    ~(on_error : unit -> 'a)
    ~(on_success : Unix.process_status -> string -> 'a) : 'a =
  match argv with
  | [] -> on_error ()
  | prog :: _ ->
      let stdout_r_ref = ref None in
      let stdout_w_ref = ref None in
      let stdin_r_ref = ref None in
      let stdin_w_ref = ref None in
      (try
         let env = default_env env in
         let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
         stdout_r_ref := Some stdout_r;
         stdout_w_ref := Some stdout_w;
         let stdin_r_opt, stdin_w_opt =
           match stdin_content with
           | None -> (None, None)
           | Some _ ->
               let r, w = Unix.pipe ~cloexec:true () in
               (Some r, Some w)
         in
         stdin_r_ref := stdin_r_opt;
         stdin_w_ref := stdin_w_opt;
         let stdin_fd =
           match !stdin_r_ref with
           | Some fd -> fd
           | None -> Unix.stdin
         in
         let pid =
           Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_w
             Unix.stderr
         in
         Option.iter close_quietly !stdin_r_ref;
         stdin_r_ref := None;
         Option.iter close_quietly !stdout_w_ref;
         stdout_w_ref := None;
         (match (stdin_content, !stdin_w_ref) with
         | Some content, Some stdin_w ->
             Fun.protect
               ~finally:(fun () ->
                 close_quietly stdin_w;
                 stdin_w_ref := None)
               (fun () ->
                 let rec write_all off =
                   if off < String.length content then
                     let n =
                       Unix.write_substring stdin_w content off
                         (String.length content - off)
                     in
                     write_all (off + n)
                 in
                 write_all 0)
         | _ -> ());
         (match !stdout_r_ref with
         | None ->
             (* stdout pipe already consumed — treat as error *)
             on_error ()
         | Some stdout_r ->
             stdout_r_ref := None;
             let ic = Unix.in_channel_of_descr stdout_r in
             let output =
               Fun.protect
                 ~finally:(fun () -> In_channel.close ic)
                 (fun () -> In_channel.input_all ic)
             in
             let (_pid, status) = Unix.waitpid [] pid in
             on_success status output)
       with
       | Eio.Cancel.Cancelled _ as exn ->
           Option.iter close_quietly !stdin_r_ref;
           stdin_r_ref := None;
           Option.iter close_quietly !stdin_w_ref;
           stdin_w_ref := None;
           Option.iter close_quietly !stdout_r_ref;
           stdout_r_ref := None;
           Option.iter close_quietly !stdout_w_ref;
           stdout_w_ref := None;
           raise exn
       | _exn ->
           Option.iter close_quietly !stdin_r_ref;
           stdin_r_ref := None;
           Option.iter close_quietly !stdin_w_ref;
           stdin_w_ref := None;
           Option.iter close_quietly !stdout_r_ref;
           stdout_r_ref := None;
           Option.iter close_quietly !stdout_w_ref;
           stdout_w_ref := None;
           on_error ())

let run_unix_argv_fallback ?env (argv : string list) : string =
  with_unix_capture ?env argv ~on_error:(fun () -> "")
    ~on_success:(fun _status output -> output)

let run_unix_argv_with_status_fallback ?env (argv : string list) :
    Unix.process_status * string =
  with_unix_capture ?env argv ~on_error:(fun () -> (Unix.WEXITED 1, ""))
    ~on_success:(fun status output -> (status, output))

let run_unix_argv_with_stdin_fallback ?env ~(stdin_content : string)
    (argv : string list) : string =
  with_unix_capture ?env ~stdin_content argv ~on_error:(fun () -> "")
    ~on_success:(fun _status output -> output)

let run_unix_argv_with_stdin_and_status_fallback
    ?env
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  with_unix_capture ?env ~stdin_content argv
    ~on_error:(fun () -> (Unix.WEXITED 1, ""))
    ~on_success:(fun status output -> (status, output))

(** ── Eio-native process execution (global refs) ─────────────────── *)

let run_argv ?(timeout_sec = 60.0) ?env (argv : string list) : string =
  if not (is_initialized ()) then run_unix_argv_fallback ?env argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_fallback ?env argv
    | Ok pm, Ok clk, Ok cwd ->
        let buf = Buffer.create 1024 in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Process.run pm ~cwd ?env ~stdout:(Eio.Flow.buffer_sink buf)
                argv;
              Buffer.contents buf)
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            ""
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_fallback ?env argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              "")

let run_argv_with_stdin ?(timeout_sec = 60.0) ?env ~(stdin_content : string) (argv : string list) : string =
  if not (is_initialized ()) then
    run_unix_argv_with_stdin_fallback ?env ~stdin_content argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_stdin_fallback ?env ~stdin_content argv
    | Ok pm, Ok clk, Ok cwd ->
        let buf = Buffer.create 1024 in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Process.run pm ~cwd ?env
                ~stdin:(Eio.Flow.string_source stdin_content)
                ~stdout:(Eio.Flow.buffer_sink buf)
                argv;
              Buffer.contents buf)
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            ""
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_stdin_fallback ?env ~stdin_content argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              "")

let run_argv_with_stdin_and_status
    ?(timeout_sec = 60.0)
    ?env
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  if not (is_initialized ()) then
    run_unix_argv_with_stdin_and_status_fallback ?env ~stdin_content argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_stdin_and_status_fallback ?env ~stdin_content argv
    | Ok pm, Ok clk, Ok cwd ->
        let buf = Buffer.create 1024 in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Switch.run (fun sw ->
                  let proc =
                    Eio.Process.spawn ~sw pm ~cwd ?env
                      ~stdin:(Eio.Flow.string_source stdin_content)
                      ~stdout:(Eio.Flow.buffer_sink buf)
                      argv
                  in
                  let status = Eio.Process.await proc in
                  let unix_status =
                    match status with
                    | `Exited n -> Unix.WEXITED n
                    | `Signaled n -> Unix.WSIGNALED n
                  in
                  (unix_status, Buffer.contents buf)))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_stdin_and_status_fallback ?env ~stdin_content
                argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              (Unix.WEXITED 1, ""))

let run_argv_with_status ?(timeout_sec = 60.0) ?env ?cwd (argv : string list) : Unix.process_status * string =
  if not (is_initialized ()) then run_unix_argv_with_status_fallback ?env argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_status_fallback ?env argv
    | Ok pm, Ok clk, Ok default_cwd ->
        let effective_cwd = match cwd with
          | None -> default_cwd
          | Some dir -> Eio.Path.(default_cwd / dir)
        in
        let buf = Buffer.create 1024 in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Switch.run (fun sw ->
                  let proc =
                    Eio.Process.spawn ~sw pm ~cwd:effective_cwd ?env
                      ~stdout:(Eio.Flow.buffer_sink buf)
                      argv
                  in
                  let status = Eio.Process.await proc in
                  let unix_status =
                    match status with
                    | `Exited n -> Unix.WEXITED n
                    | `Signaled n -> Unix.WSIGNALED n
                  in
                  (unix_status, Buffer.contents buf)))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_status_fallback ?env argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              (Unix.WEXITED 1, ""))
