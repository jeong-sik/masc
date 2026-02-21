(** Async process execution helpers for Eio

    - argv-only APIs (no shell)
    - Global proc_mgr/clock initialized once from main_eio.ml

    This module is used by tool handlers where we want:
    - Non-blocking execution (Eio fibers)
    - Injection safety (no `sh -c`)
    - Consistent output capture (stdout only)
*)

(** ── Global state (initialized once from main_eio.ml) ──────────── *)

let _proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option ref = ref None
let _clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None
let _cwd_default : Eio.Fs.dir_ty Eio.Path.t option ref = ref None

let init ~cwd_default ~proc_mgr ~clock =
  _proc_mgr := Some proc_mgr;
  _clock := Some clock;
  _cwd_default := Some cwd_default

let is_initialized () = Option.is_some !_proc_mgr

let get_proc_mgr () =
  match !_proc_mgr with
  | Some pm -> pm
  | None -> failwith "Process_eio.init not called"

let get_clock () =
  match !_clock with
  | Some c -> c
  | None -> failwith "Process_eio.init not called"

(** ── Unix fallback for tests (when Eio not initialized) ──────────── *)

let run_unix_argv_fallback (argv : string list) : string =
  match argv with
  | [] -> ""
  | prog :: _ ->
      (try
         let ic = Unix.open_process_args_in prog (Array.of_list argv) in
         Fun.protect
           ~finally:(fun () -> ignore (Unix.close_process_in ic))
           (fun () -> In_channel.input_all ic)
       with _ -> "")

let run_unix_argv_with_status_fallback (argv : string list) : Unix.process_status * string =
  match argv with
  | [] -> (Unix.WEXITED 1, "")
  | prog :: _ ->
      (try
         let ic = Unix.open_process_args_in prog (Array.of_list argv) in
         let output = In_channel.input_all ic in
         let status = Unix.close_process_in ic in
         (status, output)
       with _ -> (Unix.WEXITED 1, ""))

let run_unix_argv_with_stdin_fallback ~(stdin_content : string) (argv : string list) : string =
  match argv with
  | [] -> ""
  | prog :: _ ->
      (try
         let stdin_r, stdin_w = Unix.pipe () in
         let stdout_r, stdout_w = Unix.pipe () in
         let args = Array.of_list argv in
         let pid = Unix.create_process prog args stdin_r stdout_w Unix.stderr in
         Unix.close stdin_r;
         Unix.close stdout_w;
         Fun.protect
           ~finally:(fun () -> try Unix.close stdin_w with _ -> ())
           (fun () ->
             let rec write_all off =
               if off < String.length stdin_content then begin
                 let n =
                   Unix.write_substring stdin_w stdin_content off (String.length stdin_content - off)
                 in
                 write_all (off + n)
               end
             in
             write_all 0);
         let ic = Unix.in_channel_of_descr stdout_r in
         let output = In_channel.input_all ic in
         In_channel.close ic;
         ignore (Unix.waitpid [] pid);
         output
       with _ -> "")

let run_unix_argv_with_stdin_and_status_fallback
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  match argv with
  | [] -> (Unix.WEXITED 1, "")
  | prog :: _ ->
      (try
         let stdin_r, stdin_w = Unix.pipe () in
         let stdout_r, stdout_w = Unix.pipe () in
         let args = Array.of_list argv in
         let pid = Unix.create_process prog args stdin_r stdout_w Unix.stderr in
         Unix.close stdin_r;
         Unix.close stdout_w;
         Fun.protect
           ~finally:(fun () -> try Unix.close stdin_w with _ -> ())
           (fun () ->
             let rec write_all off =
               if off < String.length stdin_content then begin
                 let n =
                   Unix.write_substring stdin_w stdin_content off (String.length stdin_content - off)
                 in
                 write_all (off + n)
               end
             in
             write_all 0);
         let ic = Unix.in_channel_of_descr stdout_r in
         let output = In_channel.input_all ic in
         In_channel.close ic;
         let (_pid, status) = Unix.waitpid [] pid in
         (status, output)
       with _ -> (Unix.WEXITED 1, ""))

(** ── Eio-native process execution (global refs) ─────────────────── *)

let run_argv ?(timeout_sec = 60.0) ?env (argv : string list) : string =
  if not (is_initialized ()) then run_unix_argv_fallback argv
  else
    let pm = get_proc_mgr () and clk = get_clock () in
    let cwd = !_cwd_default in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Process.run pm ?cwd ?env ~stdout:(Eio.Flow.buffer_sink buf) argv;
        Buffer.contents buf)
    with
    | Eio.Time.Timeout ->
        Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label;
        ""
    | exn ->
        Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn);
        ""

let run_argv_with_stdin ?(timeout_sec = 60.0) ?env ~(stdin_content : string) (argv : string list) : string =
  if not (is_initialized ()) then run_unix_argv_with_stdin_fallback ~stdin_content argv
  else
    let pm = get_proc_mgr () and clk = get_clock () in
    let cwd = !_cwd_default in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Process.run pm ?cwd ?env
          ~stdin:(Eio.Flow.string_source stdin_content)
          ~stdout:(Eio.Flow.buffer_sink buf)
          argv;
        Buffer.contents buf)
    with
    | Eio.Time.Timeout ->
        Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label;
        ""
    | exn ->
        Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn);
        ""

let run_argv_with_stdin_and_status
    ?(timeout_sec = 60.0)
    ?env
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  if not (is_initialized ()) then run_unix_argv_with_stdin_and_status_fallback ~stdin_content argv
  else
    let pm = get_proc_mgr () and clk = get_clock () in
    let cwd = !_cwd_default in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Switch.run (fun sw ->
          let proc =
            Eio.Process.spawn ~sw pm ?cwd ?env
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
        Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label;
        (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
    | exn ->
        Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn);
        (Unix.WEXITED 1, "")

let run_argv_with_status ?(timeout_sec = 60.0) ?env (argv : string list) : Unix.process_status * string =
  if not (is_initialized ()) then run_unix_argv_with_status_fallback argv
  else
    let pm = get_proc_mgr () and clk = get_clock () in
    let cwd = !_cwd_default in
    let buf = Buffer.create 1024 in
    let label = String.concat " " (List.map Filename.quote argv) in
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () ->
        Eio.Switch.run (fun sw ->
          let proc =
            Eio.Process.spawn ~sw pm ?cwd ?env ~stdout:(Eio.Flow.buffer_sink buf) argv
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
        Eio.traceln "[Process_eio] Timeout after %.0fs: %s" timeout_sec label;
        (Unix.WSIGNALED Sys.sigterm, Buffer.contents buf)
    | exn ->
        Eio.traceln "[Process_eio] argv error: %s — %s" label (Printexc.to_string exn);
        (Unix.WEXITED 1, "")
