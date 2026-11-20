exception Break

(* Why this session ended, written once at exit. The per-PID stderr log held
   only the boot lines, so a session that ended left no reason behind: the
   operator saw roughly a hundred files a day and none said why. Set at each
   way out and written by the [at_exit] handler, which runs after the terminal
   is restored. *)
let exit_reason : Masc_tui_exit_reason.t option ref = ref None

let note reason =
  match !exit_reason with
  | Some _ -> ()
  | None -> exit_reason := Some reason

(* Written once. [at_exit] stops at the first callback that raises and OCaml
   may retry the remaining ones while it reports the exception, so a writer
   with no guard can leave two [exit:] rows for one session -- and a reader
   counting rows by cause would count that session twice. *)
let written = ref false

let write_once () =
  if not !written then begin
    written := true;
    let reason =
      match !exit_reason with
      | Some reason -> reason
      | None -> Masc_tui_exit_reason.Unrecorded
    in
    let row = "[masc-tui] " ^ Masc_tui_exit_reason.line reason ^ "\n" in
    (* Two attempts through different layers, because this row is the whole
       point of the change: a session that ends without it is unexplained
       again. [output_string] goes through the buffered channel, which can
       raise on a channel an earlier [at_exit] callback already closed; the
       raw write on the descriptor skips that layer, so it fails for
       different reasons rather than the same one. stderr is the per-PID log
       file by now ([Bootstrap.redirect_stderr_off_terminal]), and neither
       attempt is queued behind the console mirror's thread, so the row is on
       disk before the process returns.

       If both fail the failure is dropped on purpose, not by oversight: the
       descriptor this function would report on is the one that just refused,
       and raising here would take the remaining [at_exit] callbacks down
       with it. *)
    try
      output_string stderr row;
      flush stderr
    with _ -> (
      (* fire-and-forget: the note above says why this failure is dropped. *)
      try ignore (Unix.write_substring Unix.stderr row 0 (String.length row))
      with _ -> ())
  end

let signal_name signal =
  if signal = Sys.sigterm then "SIGTERM"
  else if signal = Sys.sighup then "SIGHUP"
  else if signal = Sys.sigquit then "SIGQUIT"
  else Printf.sprintf "signal %d" signal
