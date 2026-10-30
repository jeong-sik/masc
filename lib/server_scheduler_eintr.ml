type shutdown_signal =
  | Sigterm
  | Sigint

type context = {
  pending_shutdown : shutdown_signal option;
  uptime_s : float;
  mcp_sessions : int;
  ws_sessions : int option;
  ocaml_version : string;
  masc_version : string;
  git_commit : string option;
  pid : int;
}

let shutdown_signal_name = function
  | Sigterm -> "SIGTERM"
  | Sigint -> "SIGINT"
;;

let describe ctx ~syscall ~backtrace =
  let pending =
    match ctx.pending_shutdown with
    | None -> "none"
    | Some signal -> shutdown_signal_name signal
  in
  let git_commit =
    match ctx.git_commit with
    | None -> "unknown"
    | Some sha -> sha
  in
  let ws_sessions =
    match ctx.ws_sessions with
    | None -> "busy"
    | Some n -> string_of_int n
  in
  let trailing_newline =
    if String.ends_with ~suffix:"\n" backtrace then "" else "\n"
  in
  Printf.sprintf
    "[FATAL] scheduler EINTR: Unix EINTR from %s escaped Eio_main.run; the \
     scheduler cannot be resumed.\n\
     Likely cause: eio_posix clear_event_fd does not retry EINTR in the \
     locked eio (masc#43225); upstream fix \
     ocaml-multicore/eio@9480f2a9a4e6 is unreleased.\n\
     Signal state: pending shutdown signal: %s (a runtime-internal delivery \
     such as OCaml SIGURG leaves no record here).\n\
     Process state: pid=%d uptime_s=%.1f mcp_sessions=%d ws_sessions=%s \
     ocaml=%s masc=%s git=%s.\n\
     Backtrace:\n\
     %s%s"
    syscall
    pending
    ctx.pid
    ctx.uptime_s
    ctx.mcp_sessions
    ws_sessions
    ctx.ocaml_version
    ctx.masc_version
    git_commit
    backtrace
    trailing_newline
;;
