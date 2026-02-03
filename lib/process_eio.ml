(** Async process execution helpers for Eio

    Replaces blocking Unix.open_process_in calls with Eio-native async execution.
    This prevents blocking the HTTP server when running external commands.
*)

(** Run a shell command and capture stdout.
    Returns the output as a string, or empty string on failure.

    @param sw The Eio switch for resource management
    @param proc_mgr The Eio process manager
    @param cmd The shell command to run
    @param timeout_sec Optional timeout in seconds (default: 30.0)
*)
let run_capture_stdout ~sw:_sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : string =
  let buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run proc_mgr
        ~stdout:(Eio.Flow.buffer_sink buf)
        ["sh"; "-c"; cmd];
      Buffer.contents buf
    )
  with
  | Eio.Time.Timeout ->
      Eio.traceln "[Process] Timeout after %.0fs: %s" timeout_sec cmd;
      ""
  | exn ->
      Eio.traceln "[Process] Error running command: %s - %s" cmd (Printexc.to_string exn);
      ""

(** Run a shell command and capture stdout with clock parameter.
    Use this when you have access to the clock.
*)
let run_capture_stdout_with_clock ~sw:_sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : string =
  let buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run proc_mgr
        ~stdout:(Eio.Flow.buffer_sink buf)
        ["sh"; "-c"; cmd];
      Buffer.contents buf
    )
  with
  | Eio.Time.Timeout ->
      Eio.traceln "[Process] Timeout after %.0fs: %s" timeout_sec cmd;
      ""
  | exn ->
      Eio.traceln "[Process] Error running command: %s - %s" cmd (Printexc.to_string exn);
      ""

(** Run a shell command and return exit status.
    Returns true if command succeeded (exit code 0).
*)
let run_status ~sw:_sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : bool =
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run proc_mgr ["sh"; "-c"; cmd];
      true
    )
  with
  | Eio.Time.Timeout ->
      Eio.traceln "[Process] Timeout after %.0fs: %s" timeout_sec cmd;
      false
  | _ -> false

(** Run command with stdin input and capture stdout *)
let run_with_stdin ~sw:_sw ~proc_mgr ~clock ?(timeout_sec=30.0) ~stdin_content cmd : string =
  let stdout_buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run proc_mgr
        ~stdin:(Eio.Flow.string_source stdin_content)
        ~stdout:(Eio.Flow.buffer_sink stdout_buf)
        ["sh"; "-c"; cmd];
      Buffer.contents stdout_buf
    )
  with
  | Eio.Time.Timeout ->
      Eio.traceln "[Process] Timeout after %.0fs: %s" timeout_sec cmd;
      ""
  | exn ->
      Eio.traceln "[Process] Error: %s - %s" cmd (Printexc.to_string exn);
      ""

(** Read all lines from a process output (replacement for input_line loop) *)
let read_all_lines ~sw:_sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : string list =
  let output = run_capture_stdout_with_clock ~sw:_sw ~proc_mgr ~clock ~timeout_sec cmd in
  String.split_on_char '\n' output
  |> List.filter (fun s -> String.length s > 0)

(** Run command in background (fire and forget) *)
let run_detached ~sw ~proc_mgr cmd : unit =
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Process.run proc_mgr ["sh"; "-c"; cmd ^ " &"]
    with _ -> ()
  )

(* ── Systhread variants (no proc_mgr needed) ──────────────────── *)

(** Internal: read from file descriptor with deadline.
    Returns (timed_out, accumulated_content). *)
let read_fd_with_timeout fd timeout_sec =
  let buf = Buffer.create 1024 in
  let deadline = Unix.gettimeofday () +. timeout_sec in
  let tmp = Bytes.create 4096 in
  let timed_out = ref false in
  (try
    let continue = ref true in
    while !continue do
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then
        (timed_out := true; continue := false)
      else
        match Unix.select [fd] [] [] (min remaining 1.0) with
        | ([], _, _) -> ()
        | _ ->
          let n = Unix.read fd tmp 0 4096 in
          if n = 0 then continue := false
          else Buffer.add_subbytes buf tmp 0 n
    done
  with Unix.Unix_error _ -> ());
  (!timed_out, Buffer.contents buf)

(** Internal: kill child process and reap. *)
let kill_and_reap pid =
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  Unix.sleepf 0.1;
  (match try Unix.waitpid [Unix.WNOHANG] pid with Unix.Unix_error _ -> (pid, Unix.WEXITED 1) with
   | (0, _) ->
     (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
     (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ())
   | _ -> ())

(** Run shell command in a system thread with timeout (non-blocking to Eio).
    Returns stdout as string. Empty string on timeout or error.
    Default timeout: 60s. *)
let run_in_systhread ?(timeout_sec=60.0) cmd =
  Eio_unix.run_in_systhread (fun () ->
    let (rd, wr) = Unix.pipe () in
    let pid =
      Unix.create_process "/bin/sh" [|"/bin/sh"; "-c"; cmd|]
        Unix.stdin wr Unix.stderr
    in
    Unix.close wr;
    Fun.protect ~finally:(fun () ->
      (try Unix.close rd with Unix.Unix_error _ -> ());
      match try Unix.waitpid [Unix.WNOHANG] pid with Unix.Unix_error _ -> (pid, Unix.WEXITED 1) with
      | (0, _) -> kill_and_reap pid
      | _ -> ()
    ) (fun () ->
      let (timed_out, content) = read_fd_with_timeout rd timeout_sec in
      if timed_out then
        Printf.eprintf "[Process_eio] Timeout after %.0fs: %s\n%!" timeout_sec cmd;
      content
    )
  )

(** Run shell command in a system thread with timeout (non-blocking to Eio).
    Returns (Unix.process_status, stdout).
    On timeout returns (WSIGNALED Sys.sigterm, partial_output).
    Default timeout: 60s. *)
let run_in_systhread_with_status ?(timeout_sec=60.0) cmd =
  Eio_unix.run_in_systhread (fun () ->
    let (rd, wr) = Unix.pipe () in
    let pid =
      Unix.create_process "/bin/sh" [|"/bin/sh"; "-c"; cmd|]
        Unix.stdin wr Unix.stderr
    in
    Unix.close wr;
    let result = ref (Unix.WSIGNALED Sys.sigterm, "") in
    Fun.protect ~finally:(fun () ->
      (try Unix.close rd with Unix.Unix_error _ -> ());
      match try Unix.waitpid [Unix.WNOHANG] pid with Unix.Unix_error _ -> (pid, Unix.WEXITED 1) with
      | (0, _) -> kill_and_reap pid
      | _ -> ()
    ) (fun () ->
      let (timed_out, content) = read_fd_with_timeout rd timeout_sec in
      if timed_out then begin
        Printf.eprintf "[Process_eio] Timeout after %.0fs: %s\n%!" timeout_sec cmd;
        result := (Unix.WSIGNALED Sys.sigterm, content)
      end else begin
        let (_, status) =
          try Unix.waitpid [] pid
          with Unix.Unix_error _ -> (pid, Unix.WEXITED 1)
        in
        result := (status, content)
      end
    );
    !result
  )
