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
let run_capture_stdout ~sw ~proc_mgr ?(timeout_sec=30.0) cmd : string =
  let buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock (Eio.Stdenv.v ())) timeout_sec (fun () ->
      Eio.Process.run ~sw proc_mgr
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
let run_capture_stdout_with_clock ~sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : string =
  let buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run ~sw proc_mgr
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
let run_status ~sw ~proc_mgr ?(timeout_sec=30.0) cmd : bool =
  try
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock (Eio.Stdenv.v ())) timeout_sec (fun () ->
      Eio.Process.run ~sw proc_mgr ["sh"; "-c"; cmd];
      true
    )
  with
  | Eio.Time.Timeout ->
      Eio.traceln "[Process] Timeout after %.0fs: %s" timeout_sec cmd;
      false
  | _ -> false

(** Run command with stdin input and capture stdout *)
let run_with_stdin ~sw ~proc_mgr ~clock ?(timeout_sec=30.0) ~stdin_content cmd : string =
  let stdout_buf = Buffer.create 1024 in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      Eio.Process.run ~sw proc_mgr
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
let read_all_lines ~sw ~proc_mgr ~clock ?(timeout_sec=30.0) cmd : string list =
  let output = run_capture_stdout_with_clock ~sw ~proc_mgr ~clock ~timeout_sec cmd in
  String.split_on_char '\n' output
  |> List.filter (fun s -> String.length s > 0)

(** Run command in background (fire and forget) *)
let run_detached ~sw ~proc_mgr cmd : unit =
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Process.run ~sw proc_mgr ["sh"; "-c"; cmd ^ " &"]
    with _ -> ()
  )
