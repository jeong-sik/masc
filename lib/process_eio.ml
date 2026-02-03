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

(* ── Global state (initialized once from main_eio.ml) ──────────── *)

let _proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option ref = ref None
let _clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None

let init ~proc_mgr ~clock =
  _proc_mgr := Some proc_mgr;
  _clock := Some clock

let is_initialized () = Option.is_some !_proc_mgr

let get_proc_mgr () = match !_proc_mgr with
  | Some pm -> pm
  | None -> failwith "Process_eio.init not called"

let get_clock () = match !_clock with
  | Some c -> c
  | None -> failwith "Process_eio.init not called"

(* ── Unix fallback for tests (when Eio not initialized) ──────────── *)

let run_unix_fallback cmd =
  try
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
      In_channel.input_all ic
    )
  with _ -> ""

let run_unix_fallback_with_status cmd =
  try
    let ic, oc, ec = Unix.open_process_full cmd (Unix.environment ()) in
    let output = In_channel.input_all ic in
    close_out_noerr oc;
    ignore (In_channel.input_all ec);
    let status = Unix.close_process_full (ic, oc, ec) in
    (status, output)
  with _ -> (Unix.WEXITED 1, "")

(* ── Eio-native replacements for run_in_systhread ──────────────── *)

(** Run a shell command, capture stdout. Empty on timeout/error.
    Uses Eio.Process.run (raises on non-zero exit → caught).
    Falls back to Unix when Eio not initialized (for tests). *)
let run ?(timeout_sec=60.0) cmd =
  if not (is_initialized ()) then run_unix_fallback cmd
  else begin
    let pm = get_proc_mgr () and clk = get_clock () in
    let buf = Buffer.create 1024 in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Process.run pm
          ~stdout:(Eio.Flow.buffer_sink buf)
          ["sh"; "-c"; cmd];
        Buffer.contents buf)
    with
    | Eio.Time.Timeout ->
      Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec cmd; ""
    | exn ->
      Eio.traceln "[Process_eio] Error: %s — %s" cmd (Printexc.to_string exn); ""
  end

(* Unix fallback for argv-based commands *)
let run_unix_argv_fallback argv =
  try
    let cmd = List.hd argv in
    let args = Array.of_list argv in
    let ic = Unix.open_process_args_in cmd args in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
      In_channel.input_all ic
    )
  with _ -> ""

let run_unix_argv_with_status_fallback argv =
  try
    let cmd = List.hd argv in
    let args = Array.of_list argv in
    let ic = Unix.open_process_args_in cmd args in
    let output = In_channel.input_all ic in
    let status = Unix.close_process_in ic in
    (status, output)
  with _ -> (Unix.WEXITED 1, "")

(** Run a command with explicit argv (NO shell). Safe from injection.
    Use this instead of [run] when the command doesn't need pipes/redirects.

    Example: [run_argv ~timeout_sec:10.0 ["curl"; "-s"; url]]

    @since 2.45.0 *)
let run_argv ?(timeout_sec=60.0) argv =
  if not (is_initialized ()) then run_unix_argv_fallback argv
  else begin
    let pm = get_proc_mgr () and clk = get_clock () in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Process.run pm
          ~stdout:(Eio.Flow.buffer_sink buf)
          argv;
        Buffer.contents buf)
    with
    | Eio.Time.Timeout ->
      Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label; ""
    | exn ->
      Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn); ""
  end

(** Run a command with explicit argv and stdin input (NO shell).
    Body is piped to the process's stdin.

    Example: [run_argv_with_stdin ~stdin_content:json_body ["curl"; "-s"; "-d"; "@-"; url]]

    @since 2.45.0 *)
let run_argv_with_stdin ?(timeout_sec=60.0) ~stdin_content argv =
  if not (is_initialized ()) then begin
    (* Fallback: write stdin to temp file and use shell *)
    let tmp = Filename.temp_file "stdin_" ".txt" in
    Fun.protect ~finally:(fun () -> try Sys.remove tmp with _ -> ()) (fun () ->
      Out_channel.with_open_bin tmp (fun oc -> Out_channel.output_string oc stdin_content);
      let cmd = Printf.sprintf "%s < %s" (String.concat " " (List.map Filename.quote argv)) (Filename.quote tmp) in
      run_unix_fallback cmd
    )
  end else begin
    let pm = get_proc_mgr () and clk = get_clock () in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Process.run pm
          ~stdin:(Eio.Flow.string_source stdin_content)
          ~stdout:(Eio.Flow.buffer_sink buf)
          argv;
        Buffer.contents buf)
    with
    | Eio.Time.Timeout ->
      Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label; ""
    | exn ->
      Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn); ""
  end

(** Run a command with explicit argv, return (Unix.process_status, stdout).
    Uses Eio.Process.spawn + await to get exit status without raising.
    @since 2.45.0 *)
let run_argv_with_status ?(timeout_sec=60.0) argv =
  if not (is_initialized ()) then run_unix_argv_with_status_fallback argv
  else begin
    let pm = get_proc_mgr () and clk = get_clock () in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Switch.run (fun sw ->
          let proc = Eio.Process.spawn ~sw pm
            ~stdout:(Eio.Flow.buffer_sink buf)
            argv in
          let status = Eio.Process.await proc in
          let unix_status = match status with
            | `Exited n -> Unix.WEXITED n
            | `Signaled n -> Unix.WSIGNALED n in
          (unix_status, Buffer.contents buf)))
    with
    | Eio.Time.Timeout ->
      Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label;
      (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
    | exn ->
      Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn);
      (Unix.WEXITED 1, "")
  end

(** Run a shell command, return (Unix.process_status, stdout).
    Uses Eio.Process.spawn + await to get exit status without raising. *)
let run_with_status ?(timeout_sec=60.0) cmd =
  if not (is_initialized ()) then run_unix_fallback_with_status cmd
  else begin
    let pm = get_proc_mgr () and clk = get_clock () in
    let buf = Buffer.create 1024 in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Switch.run (fun sw ->
          let proc = Eio.Process.spawn ~sw pm
            ~stdout:(Eio.Flow.buffer_sink buf)
            ["sh"; "-c"; cmd] in
          let status = Eio.Process.await proc in
          let unix_status = match status with
            | `Exited n -> Unix.WEXITED n
            | `Signaled n -> Unix.WSIGNALED n in
          (unix_status, Buffer.contents buf)))
    with
    | Eio.Time.Timeout ->
      Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec cmd;
      (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
    | exn ->
      Eio.traceln "[Process_eio] Error: %s — %s" cmd (Printexc.to_string exn);
      (Unix.WEXITED 1, "")
  end
