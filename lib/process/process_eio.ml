(** Async process execution helpers for Eio

    - argv-only APIs (no shell)
    - Global proc_mgr/clock initialized once from main_eio.ml

    This module is used by tool handlers where we want:
    - Non-blocking execution (Eio fibers)
    - Injection safety (no `sh -c`)
    - Consistent output capture (stdout; status APIs also surface stderr on failures)
*)

(** ── Global state (initialized once from main_eio.ml) ──────────── *)

type runtime = {
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cwd_default : Eio.Fs.dir_ty Eio.Path.t;
}

(** [Atomic.t] rather than a plain [ref] because subprocess spawns from
    Executor_pool workers (distinct OCaml 5 domains) read this state;
    without a memory barrier a worker domain can observe [None] even
    after [init] has published the runtime on the main domain. *)
let runtime_state : runtime option Atomic.t = Atomic.make None

let init ~cwd_default ~proc_mgr ~clock =
  Atomic.set runtime_state (Some { proc_mgr; clock; cwd_default })

let is_initialized () = Option.is_some (Atomic.get runtime_state)

let reset_for_testing () =
  Atomic.set runtime_state None

let default_buffer_size = 1024

let get_proc_mgr () =
  match Atomic.get runtime_state with
  | Some runtime -> Ok runtime.proc_mgr
  | None -> Error "Process_eio.get_proc_mgr: init not called"

let get_clock () =
  match Atomic.get runtime_state with
  | Some runtime -> Ok runtime.clock
  | None -> Error "Process_eio.get_clock: init not called"

let get_cwd_default () =
  match Atomic.get runtime_state with
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

let unix_cwd_mutex = Stdlib.Mutex.create ()

let create_process_env ?cwd prog argv env stdin_fd stdout_fd stderr_fd =
  match cwd with
  | None -> Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_fd stderr_fd
  | Some dir ->
      Stdlib.Mutex.lock unix_cwd_mutex;
      let original_dir = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () ->
          Safe_ops.protect ~default:() (fun () -> Sys.chdir original_dir);
          Stdlib.Mutex.unlock unix_cwd_mutex)
        (fun () ->
          Sys.chdir dir;
          Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_fd stderr_fd)

let output_for_status ~(status : Unix.process_status) ~(stdout : string)
    ~(stderr : string) : string =
  let succeeded =
    match status with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  in
  if succeeded then stdout
  else
    match stdout, stderr with
    | "", err -> err
    | out, "" -> out
    | out, err -> out ^ "\n" ^ err

let process_error_output ?(stderr = "") ~label:_ ~reason () =
  let stderr = String.trim stderr in
  if stderr = "" then
    Printf.sprintf "process_eio_error: %s" reason
  else
    Printf.sprintf "process_eio_error: %s\nstderr:\n%s" reason stderr

let reason_of_exn_for_output = function
  | Unix.Unix_error (err, fn, _) ->
      Printf.sprintf "%s: %s" fn (Unix.error_message err)
  | exn -> Printexc.to_string exn

(** Create a private stderr capture file for Unix fallback status helpers.
    Uses [Filename.temp_file] for atomic creation, then opens the file with
    private permissions and marks the descriptor close-on-exec to avoid
    descriptor leaks into unrelated child processes. *)
let create_stderr_tempfile () =
  let path = Filename.temp_file "masc_process_eio_stderr" ".tmp" in
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600
  in
  (path, fd)

let remove_temp_file_quietly path =
  try Sys.remove path with
  | Sys_error _ -> ()

let read_stderr_capture path =
  try In_channel.with_open_bin path In_channel.input_all with
  | _exn ->
      Printf.sprintf
        "(stderr capture error) failed to read captured stderr file %s. Check temp-file permissions or available temp storage."
        (Filename.basename path)

let captured_stderr_or_empty path_opt =
  match path_opt with
  | Some path -> read_stderr_capture path
  | None -> ""

let with_unix_capture ?env ?cwd ?stdin_content ?(capture_stderr = false)
    ?(timeout_sec = 60.0)
    (argv : string list)
    ~(on_error : string -> string -> 'a)
    ~(on_success : Unix.process_status -> string -> string -> 'a) : 'a =
  match argv with
  | [] -> on_error "empty argv" ""
  | prog :: _ ->
    let stdout_r_ref = ref None in
    let stdout_w_ref = ref None in
    let stderr_fd_ref = ref None in
    let stderr_path_ref = ref None in
    let stdin_r_ref = ref None in
    let stdin_w_ref = ref None in
    let cleanup () =
      Option.iter close_quietly !stdin_r_ref;
      stdin_r_ref := None;
      Option.iter close_quietly !stdin_w_ref;
      stdin_w_ref := None;
      Option.iter close_quietly !stdout_r_ref;
      stdout_r_ref := None;
      Option.iter close_quietly !stdout_w_ref;
      stdout_w_ref := None;
      Option.iter close_quietly !stderr_fd_ref;
      stderr_fd_ref := None;
      Option.iter
        remove_temp_file_quietly
        !stderr_path_ref;
      stderr_path_ref := None
    in
    (try
       let env = default_env env in
       let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
       stdout_r_ref := Some stdout_r;
       stdout_w_ref := Some stdout_w;
       (* stderr is captured into a temp file and read back after [waitpid]
          completes so the parent never blocks the child on an unread stderr
          pipe in Unix fallback mode. *)
       let stderr_fd =
         if capture_stderr
         then (
           let path, fd = create_stderr_tempfile () in
           stderr_path_ref := Some path;
           stderr_fd_ref := Some fd;
           fd)
         else
           Unix.stderr
       in
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
         create_process_env ?cwd prog argv env stdin_fd stdout_w stderr_fd
       in
       Option.iter close_quietly !stdin_r_ref;
       stdin_r_ref := None;
       Option.iter close_quietly !stdout_w_ref;
       stdout_w_ref := None;
       (* The child inherited the descriptor during spawn; the parent no longer
          needs its copy once the process exits. *)
       Option.iter close_quietly !stderr_fd_ref;
       stderr_fd_ref := None;
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
        | (None, _) | (Some _, None) -> ());
       (match !stdout_r_ref with
        | None ->
            (* stdout pipe already consumed — treat as error *)
            cleanup ();
            on_error "stdout pipe unavailable during Unix fallback capture" ""
        | Some stdout_r ->
            stdout_r_ref := None;
            let rec waitpid_blocking () =
              try Unix.waitpid [] pid
              with
              | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_blocking ()
              | Unix.Unix_error (Unix.ECHILD, _, _) -> (pid, Unix.WEXITED 127)
            in
            let kill_and_wait status_ref =
              (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
              if Option.is_none !status_ref then
                let (_pid, status) = waitpid_blocking () in
                status_ref := Some status
            in
            let waitpid_nohang () =
              try
                match Unix.waitpid [ Unix.WNOHANG ] pid with
                | 0, _ -> None
                | _, status -> Some status
              with
              | Unix.Unix_error (Unix.EINTR, _, _) -> None
              | Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 127)
            in
            let stdout_buf = Buffer.create default_buffer_size in
            let chunk = Bytes.create 4096 in
            let read_available () =
              let rec loop () =
                try
                  match Unix.read stdout_r chunk 0 (Bytes.length chunk) with
                  | 0 -> `Eof
                  | n ->
                      Buffer.add_subbytes stdout_buf chunk 0 n;
                      loop ()
                with
                | Unix.Unix_error
                    ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                    `Would_block
                | Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
              in
              loop ()
            in
            let timeout_sec = max 0.001 timeout_sec in
            let deadline = Unix.gettimeofday () +. timeout_sec in
            let timed_out = ref false in
            let status_ref = ref None in
            let stdout_eof = ref false in
            Unix.set_nonblock stdout_r;
            while (not !stdout_eof) && not !timed_out do
              if Unix.gettimeofday () >= deadline then begin
                timed_out := true;
                kill_and_wait status_ref;
                ignore (read_available () : [ `Eof | `Would_block ])
              end else begin
                let remaining = max 0.0 (deadline -. Unix.gettimeofday ()) in
                let readable =
                  try
                    let ready, _, _ =
                      Unix.select [ stdout_r ] [] [] (min 0.05 remaining)
                    in
                    ready <> []
                  with Unix.Unix_error (Unix.EINTR, _, _) -> false
                in
                if readable then
                  match read_available () with
                  | `Eof -> stdout_eof := true
                  | `Would_block -> ()
              end
            done;
            while (not !timed_out) && Option.is_none !status_ref do
              match waitpid_nohang () with
              | Some status -> status_ref := Some status
              | None ->
                  if Unix.gettimeofday () >= deadline then begin
                    timed_out := true;
                    kill_and_wait status_ref
                  end else
                    (try
                       ignore
                         (Unix.select [] [] []
                            (min 0.05
                               (max 0.0 (deadline -. Unix.gettimeofday ()))))
                     with Unix.Unix_error (Unix.EINTR, _, _) -> ())
            done;
            close_quietly stdout_r;
            let status =
              if !timed_out then Unix.WEXITED 124
              else
                match !status_ref with
                | Some status -> status
                | None ->
                    let (_pid, status) = waitpid_blocking () in
                    status
            in
            let stdout = Buffer.contents stdout_buf in
            let stderr = captured_stderr_or_empty !stderr_path_ref in
            let stderr =
              if !timed_out && String.trim stdout = ""
                 && String.trim stderr = ""
              then
                process_error_output
                  ~label:(String.concat " " (List.map Filename.quote argv))
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec)
                  ()
              else stderr
            in
            cleanup ();
            on_success status stdout stderr)
     with
     | Eio.Cancel.Cancelled _ as exn ->
         cleanup ();
         raise exn
     | exn ->
         let stderr = captured_stderr_or_empty !stderr_path_ref in
         cleanup ();
         on_error (reason_of_exn_for_output exn) stderr)

let run_unix_argv_fallback ?(timeout_sec = 60.0) ?env (argv : string list) : string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ~timeout_sec argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      process_error_output ~label ~reason ~stderr ())
    ~on_success:(fun status stdout stderr ->
      output_for_status ~status ~stdout ~stderr)

let run_unix_argv_with_status_split_fallback ?(timeout_sec = 60.0) ?env ?cwd (argv : string list) :
    Unix.process_status * string * string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?cwd ~timeout_sec ~capture_stderr:true argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      (Unix.WEXITED 127, "", process_error_output ~label ~reason ~stderr ()))
    ~on_success:(fun status stdout stderr ->
      (status, stdout, stderr))

let run_unix_argv_with_stdin_fallback ?(timeout_sec = 60.0) ?env ~(stdin_content : string)
    (argv : string list) : string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ~timeout_sec ~stdin_content argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      process_error_output ~label ~reason ~stderr ())
    ~on_success:(fun status stdout stderr ->
      output_for_status ~status ~stdout ~stderr)

let run_unix_argv_with_stdin_and_status_split_fallback
    ?(timeout_sec = 60.0)
    ?env
    ?cwd
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?cwd ~timeout_sec ~stdin_content ~capture_stderr:true argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      (Unix.WEXITED 127, "", process_error_output ~label ~reason ~stderr ()))
    ~on_success:(fun status stdout stderr ->
      (status, stdout, stderr))

(** ── Eio-native process execution (global refs) ─────────────────── *)

(** Spawn a process with explicit pipes and drain stdout/stderr into buffers
    before returning.  This avoids a race where [Eio.Process.await] returns
    (process exited) but the internal copy-fiber that moves pipe data into
    [buffer_sink] has not finished yet, resulting in truncated/empty output.

    The fix mirrors [Eio.Process.parse_out]: create pipes, close write ends
    after spawn, read to EOF in parallel fibers, then await the exit status. *)
let spawn_and_drain_stdout ~sw pm ~cwd ?env ?stdin_source argv stdout_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw pm ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      argv
  in
  Eio.Flow.close stdout_w;
  (* Drain to EOF before await — pipe close is switch-managed on cancel. *)
  (try
     Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
     Eio.Flow.close stdout_r
   with Eio.Cancel.Cancelled _ as e ->
     (try Eio.Flow.close stdout_r with Eio.Cancel.Cancelled _ as ce -> raise ce | exn -> Log.Misc.warn "spawn_and_drain_stdout: flow close failed: %s" (Printexc.to_string exn));
     raise e);
  let status = Eio.Process.await proc in
  match status with
  | `Exited n -> Unix.WEXITED n
  | `Signaled n -> Unix.WSIGNALED n

(** Like [spawn_and_drain_stdout] but captures both stdout and stderr into
    separate buffers and returns the process exit status.
    Drain happens in parallel via [Fiber.both]; [await] is called after
    both pipes reach EOF, so buffers are guaranteed complete. *)
let spawn_and_drain_both ~sw pm ~cwd ?env ?stdin_source argv stdout_buf
    stderr_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw pm ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      ~stderr:stderr_w
      argv
  in
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  (try
     Eio.Fiber.both
       (fun () ->
         Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
         Eio.Flow.close stdout_r)
       (fun () ->
         Eio.Flow.copy stderr_r (Eio.Flow.buffer_sink stderr_buf);
         Eio.Flow.close stderr_r)
   with Eio.Cancel.Cancelled _ as e ->
     (try Eio.Flow.close stdout_r with Eio.Cancel.Cancelled _ as ce -> raise ce | exn -> Log.Misc.warn "spawn_and_drain_both: stdout flow close failed: %s" (Printexc.to_string exn));
     (try Eio.Flow.close stderr_r with Eio.Cancel.Cancelled _ as ce -> raise ce | exn -> Log.Misc.warn "spawn_and_drain_both: stderr flow close failed: %s" (Printexc.to_string exn));
     raise e);
  let status = Eio.Process.await proc in
  match status with
  | `Exited n -> Unix.WEXITED n
  | `Signaled n -> Unix.WSIGNALED n

let run_argv ?(timeout_sec = 60.0) ?env (argv : string list) : string =
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv ~argv ?env ();
  if not (is_initialized ()) then
    run_unix_argv_fallback ~timeout_sec ?env argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_fallback ~timeout_sec ?env argv
    | Ok pm, Ok clk, Ok cwd ->
        let buf = Buffer.create default_buffer_size in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Switch.run (fun sw ->
                  let status = spawn_and_drain_stdout ~sw pm ~cwd ?env argv buf in
                  output_for_status ~status ~stdout:(Buffer.contents buf) ~stderr:""))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            process_error_output ~label
              ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_fallback ~timeout_sec ?env argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              process_error_output ~label ~reason:(reason_of_exn_for_output exn) ())

let run_argv_with_stdin ?(timeout_sec = 60.0) ?env ~(stdin_content : string) (argv : string list) : string =
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin ~argv ?env ();
  if not (is_initialized ()) then
    run_unix_argv_with_stdin_fallback ~timeout_sec ?env ~stdin_content argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_stdin_fallback ~timeout_sec ?env ~stdin_content argv
    | Ok pm, Ok clk, Ok cwd ->
        let buf = Buffer.create default_buffer_size in
        let label = String.concat " " (List.map Filename.quote argv) in
        let stdin_source = Eio.Flow.string_source stdin_content in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              Eio.Switch.run (fun sw ->
                  let status = spawn_and_drain_stdout ~sw pm ~cwd ?env ~stdin_source argv buf in
                  output_for_status ~status ~stdout:(Buffer.contents buf) ~stderr:""))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            process_error_output ~label
              ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_stdin_fallback ~timeout_sec ?env ~stdin_content argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              process_error_output ~label ~reason:(reason_of_exn_for_output exn) ())

let run_argv_with_stdin_and_status_split
    ?(timeout_sec = 60.0)
    ?env
    ?cwd
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin_and_status ~argv ?env ();
  if not (is_initialized ()) then
    run_unix_argv_with_stdin_and_status_split_fallback ~timeout_sec ?env ?cwd
      ~stdin_content argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_stdin_and_status_split_fallback ~timeout_sec ?env ?cwd
          ~stdin_content argv
    | Ok pm, Ok clk, Ok default_cwd ->
        let effective_cwd =
          match cwd with
          | None -> default_cwd
          | Some dir -> Eio.Path.(default_cwd / dir)
        in
        let stdout_buf = Buffer.create default_buffer_size in
        let stderr_buf = Buffer.create default_buffer_size in
        let label = String.concat " " (List.map Filename.quote argv) in
        let stdin_source = Eio.Flow.string_source stdin_content in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              let unix_status =
                Eio.Switch.run (fun sw ->
                    spawn_and_drain_both ~sw pm ~cwd:effective_cwd ?env
                      ~stdin_source argv stdout_buf stderr_buf)
              in
              (unix_status, Buffer.contents stdout_buf, Buffer.contents stderr_buf))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            let timeout_status = Unix.WEXITED 124 in
            let stdout = Buffer.contents stdout_buf in
            let stderr = Buffer.contents stderr_buf in
            let stderr =
              if String.trim stdout = "" && String.trim stderr = "" then
                process_error_output ~label
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
              else stderr
            in
            (timeout_status, stdout, stderr)
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_stdin_and_status_split_fallback ~timeout_sec
                ?env ?cwd ~stdin_content argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              ( Unix.WEXITED 127,
                "",
                process_error_output ~label
                  ~reason:(reason_of_exn_for_output exn) () ))

let run_argv_with_stdin_and_status
    ?(timeout_sec = 60.0)
    ?env
    ?cwd
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  let status, stdout, stderr =
    run_argv_with_stdin_and_status_split ~timeout_sec ?env ?cwd ~stdin_content
      argv
  in
  (status, output_for_status ~status ~stdout ~stderr)

let run_argv_with_status_split ?(timeout_sec = 60.0) ?env ?cwd
    (argv : string list) : Unix.process_status * string * string =
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  if not (is_initialized ()) then
    run_unix_argv_with_status_split_fallback ~timeout_sec ?env ?cwd argv
  else
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
        run_unix_argv_with_status_split_fallback ~timeout_sec ?env ?cwd argv
    | Ok pm, Ok clk, Ok default_cwd ->
        let effective_cwd =
          match cwd with
          | None -> default_cwd
          | Some dir -> Eio.Path.(default_cwd / dir)
        in
        let stdout_buf = Buffer.create default_buffer_size in
        let stderr_buf = Buffer.create 256 in
        let label = String.concat " " (List.map Filename.quote argv) in
        try
          Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
              let unix_status =
                Eio.Switch.run (fun sw ->
                    spawn_and_drain_both ~sw pm ~cwd:effective_cwd ?env argv
                      stdout_buf stderr_buf)
              in
              (unix_status, Buffer.contents stdout_buf, Buffer.contents stderr_buf))
        with
        | Eio.Time.Timeout ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs: %s"
              timeout_sec label;
            let timeout_status = Unix.WEXITED 124 in
            let stdout = Buffer.contents stdout_buf in
            let stderr = Buffer.contents stderr_buf in
            let stderr =
              if String.trim stdout = "" && String.trim stderr = "" then
                process_error_output ~label
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
              else stderr
            in
            (timeout_status, stdout, stderr)
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            if should_retry_unix_fallback exn then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              run_unix_argv_with_status_split_fallback ~timeout_sec ?env ?cwd argv
            ) else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              ( Unix.WEXITED 127,
                "",
                process_error_output ~label
                  ~reason:(reason_of_exn_for_output exn) () ))

let run_argv_with_status ?(timeout_sec = 60.0) ?env ?cwd
    (argv : string list) : Unix.process_status * string =
  let status, stdout, stderr =
    run_argv_with_status_split ~timeout_sec ?env ?cwd argv
  in
  (status, output_for_status ~status ~stdout ~stderr)

(* ============================================================ *)
(* Detached (background) spawn primitives — P2 Legendary Bash   *)
(* ============================================================ *)

type detached_handle = {
  pid : int;
  pgid : int;
  stdout_fd : Unix.file_descr;
  stderr_fd : Unix.file_descr;
  started_at : float;
}

let spawn_detached ~argv ~env ~cwd =
  match argv with
  | [] -> Error "spawn_detached: empty argv"
  | bin :: _ ->
      (try
         let out_r, out_w = Unix.pipe ~cloexec:true () in
         let err_r, err_w = Unix.pipe ~cloexec:true () in
         let devnull =
           Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
         in
         (* Use fork/exec instead of create_process_env so the child
            can [setpgrp] before [execvpe].  OCaml's Unix module does
            not expose [setpgid(pid, pgid)] for the parent to call on
            a child, so the child has to establish its own process
            group authoritatively.  A short window between fork and
            setpgrp still leaves the child in the parent's group — any
            signal delivered to the parent group in that window would
            also reach the child.  Acceptable for background shells;
            signal-race-free semantics would require posix_spawn with
            POSIX_SPAWN_SETPGROUP via Ctypes, a follow-up item. *)
         let pid = Unix.fork () in
         if pid = 0 then begin
           (* --- CHILD --- *)
           (* [Unix.setsid] creates a new session AND a new process
              group with the child as leader.  OCaml's stdlib does not
              expose [setpgid], so [setsid] is the portable way to
              guarantee a new group.  Side effect: the child detaches
              from the parent's controlling terminal, which matches
              the "background shell" semantics we want. *)
           Safe_ops.protect ~default:() (fun () -> ignore (Unix.setsid ()));
           (try
              if cwd <> "" then Unix.chdir cwd
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 126);
           Unix.dup2 devnull Unix.stdin;
           Unix.dup2 out_w Unix.stdout;
           Unix.dup2 err_w Unix.stderr;
           Unix.close out_r; Unix.close err_r;
           Unix.close out_w; Unix.close err_w; Unix.close devnull;
           (try Unix.execvpe bin (Array.of_list argv) env
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 127)
         end else begin
           (* --- PARENT --- *)
           Unix.close out_w;
           Unix.close err_w;
           Unix.close devnull;
           Ok
             {
               pid;
               pgid = pid;
               stdout_fd = out_r;
               stderr_fd = err_r;
               started_at = Unix.gettimeofday ();
             }
         end
       with
       | Unix.Unix_error (err, fn, arg) ->
           Error
             (Printf.sprintf "spawn_detached %s: %s (%s %s)"
                bin (Unix.error_message err) fn arg)
       | exn ->
           Error
             (Printf.sprintf "spawn_detached %s: %s" bin
                (Printexc.to_string exn)))

let is_pgid_alive ~pgid =
  try
    Unix.kill (-pgid) 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) ->
      (* EPERM means the process exists but we can't signal it —
         conservative "alive" answer. *)
      true
  | _ -> false

let tree_kill ~pgid ~signal ~grace_sec =
  let safe_kill s =
    try Unix.kill (-pgid) s
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
    | Unix.Unix_error (Unix.EPERM, _, _) ->
        (* macOS can return EPERM after all processes in the group
           have exited but the session object lingers. Treat as
           "already gone". *)
        ()
  in
  safe_kill signal;
  if grace_sec > 0.0 then begin
    let deadline = Unix.gettimeofday () +. grace_sec in
    let step = min 0.1 (grace_sec /. 10.0) in
    let rec wait_loop () =
      if not (is_pgid_alive ~pgid) then ()
      else if Unix.gettimeofday () >= deadline then
        safe_kill Sys.sigkill
      else begin
        Safe_ops.protect ~default:() (fun () -> ignore (Unix.select [] [] [] step));
        wait_loop ()
      end
    in
    wait_loop ()
  end
