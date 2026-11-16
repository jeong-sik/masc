(* [Sys.sigX] are values, not constructors, so the names are a table that is
   searched rather than a [match]. It holds every signal [Sys] defines in the
   OCaml this repository pins (5.5.2, which added [sigio] and [sigwinch] in
   5.4); a missing one would read as its negative OCaml number. *)
let signal_names =
  [ Sys.sigabrt, "SIGABRT"; Sys.sigalrm, "SIGALRM"; Sys.sigbus, "SIGBUS"
  ; Sys.sigchld, "SIGCHLD"; Sys.sigcont, "SIGCONT"; Sys.sigfpe, "SIGFPE"
  ; Sys.sighup, "SIGHUP"; Sys.sigill, "SIGILL"; Sys.sigint, "SIGINT"
  ; Sys.sigkill, "SIGKILL"; Sys.sigpipe, "SIGPIPE"; Sys.sigpoll, "SIGPOLL"
  ; Sys.sigprof, "SIGPROF"; Sys.sigquit, "SIGQUIT"; Sys.sigsegv, "SIGSEGV"
  ; Sys.sigstop, "SIGSTOP"; Sys.sigsys, "SIGSYS"; Sys.sigterm, "SIGTERM"
  ; Sys.sigtrap, "SIGTRAP"; Sys.sigtstp, "SIGTSTP"; Sys.sigttin, "SIGTTIN"
  ; Sys.sigttou, "SIGTTOU"; Sys.sigurg, "SIGURG"; Sys.sigusr1, "SIGUSR1"
  ; Sys.sigusr2, "SIGUSR2"; Sys.sigvtalrm, "SIGVTALRM"; Sys.sigxcpu, "SIGXCPU"
  ; Sys.sigxfsz, "SIGXFSZ"; Sys.sigio, "SIGIO"; Sys.sigwinch, "SIGWINCH" ]

let signal_name signal =
  match List.assoc_opt signal signal_names with
  | Some name -> name
  | None -> Printf.sprintf "signal %d" signal

let of_status = function
  | Unix.WEXITED code -> Printf.sprintf "exited with status %d" code
  | Unix.WSIGNALED signal -> "was killed by " ^ signal_name signal
  | Unix.WSTOPPED signal -> "was stopped by " ^ signal_name signal
