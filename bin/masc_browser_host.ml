(** Firefox native messaging host: the command line of {!Browser_host}. *)

let ( let* ) = Result.bind

(* What stops a BiDi host that the operator runs in a terminal. *)
type stop_signal = Interrupt | Terminate | Hangup

let signal_number = function
  | Interrupt -> Sys.sigint
  | Terminate -> Sys.sigterm
  | Hangup -> Sys.sighup

let signal_name = function
  | Interrupt -> "SIGINT"
  | Terminate -> "SIGTERM"
  | Hangup -> "SIGHUP"

(* A hangup says the terminal is gone. A write to it fails from then on,
   which the log raises, and the host still has its session to end and the
   server to tell. So a standard error that was that terminal goes to
   /dev/null; one redirected to a file keeps receiving the log. *)
let leave_terminal () =
  (* Called from a signal handler, which must not raise; and nothing is left
     to report a failure to. *)
  match Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 with
  | exception Unix.Unix_error _ -> ()
  | null ->
    (try Unix.dup2 null Unix.stderr with Unix.Unix_error _ -> ());
    (try Unix.close null with Unix.Unix_error _ -> ())

let () =
  Log.init_from_env ();
  let base_path = ref None and server = ref None and token_file = ref None and bidi_url = ref None in
  let positional = ref [] in
  let set target value = target := Some value in
  let options =
    [ Masc.Browser_bidi_host_status.bidi_url_flag, Arg.String (set bidi_url), "URL Attach to an explicitly enabled loopback Firefox BiDi endpoint"
    ; "--base-path", Arg.String (set base_path), "PATH Workspace containing .masc (or MASC_BASE_PATH)"
    ; "--server", Arg.String (set server), "URL Fixed MASC HTTP server; without it the port comes from the workspace connection.toml, followed after a failed request only to an address that answers the lane"
    ; "--token-file", Arg.String (set token_file), "PATH Lane token (default: <base-path>/.masc/browser-lane/token)"
    ]
  in
  Arg.parse options (fun value -> positional := value :: !positional)
    "masc-browser-host [--base-path PATH] [--server URL] [--token-file PATH]";
  let arguments_valid =
    match List.rev !positional with
    | [] | [ _ ] -> true
    | [ _; "browser-lane@masc.local" ] -> true
    | _ -> false
  in
  let result =
    if not arguments_valid then Error "unexpected native host arguments"
    else if Sys.big_endian then Error "native host requires a little-endian platform"
    else
      let* config = Browser_host.resolve_config ~base_path:!base_path ~server:!server ~token_file:!token_file in
      (* Firefox owns the pipe's reader; this executable owns its writer.
         POSIX readiness does not promise that a whole native frame fits:
         a blocking writev can otherwise stop Eio's timer and stdin fibers
         on macOS. Configure before Eio first queries/caches the FD mode. *)
      let* () = match Unix.set_nonblock Unix.stdout with
        | () -> Ok ()
        | exception Unix.Unix_error _ -> Error "native stdout setup failed" in
      (* Read while the terminal is certainly there: after a hangup the
         question itself can fail. *)
      let stderr_is_terminal = Unix.isatty Unix.stderr in
      try Eio_main.run (fun env -> match !bidi_url with
        | None -> Browser_host.run env config
        | Some url ->
          (* The operator stops this host by hand. A signal is taken as a
             request, so the host ends its BiDi session and tells the server
             before it exits. The handler records the first request and wakes
             the waiting fiber, which Eio allows from a signal handler. *)
          let asked = Atomic.make None and wake = Eio.Condition.create () in
          List.iter (fun signal ->
            let number = signal_number signal in
            match Sys.signal number (Sys.Signal_handle (fun number ->
              (match signal with
               (* A second Ctrl-C is not asked to wait. *)
               | Interrupt -> Sys.set_signal number Sys.Signal_default
               (* Here and not in the waiting fiber: the terminal can also
                  close after another signal already asked. A closing
                  terminal may send its hangup twice, once from the kernel
                  and once from the shell, so a second one changes nothing. *)
               | Hangup -> if stderr_is_terminal then leave_terminal ()
               (* A second SIGTERM forces exit if graceful shutdown is stuck. *)
               | Terminate ->
                 if Atomic.get asked = None then Sys.set_signal number Sys.Signal_default
                 else Unix._exit (128 + number));
              ignore (Atomic.compare_and_set asked None (Some signal) : bool);
              Eio.Condition.broadcast wake)) with
            (* Whoever started the host ignoring a signal decided that: nohup
               for a hangup, a shell without job control for the interrupt of
               a job it put in the background. *)
            | Sys.Signal_ignore -> Sys.set_signal number Sys.Signal_ignore
            | Sys.Signal_default | Sys.Signal_handle _ -> ())
            [ Interrupt; Terminate; Hangup ];
          Browser_host.run_bidi env config url
            ~stop:(fun () ->
              let signal = Eio.Condition.loop_no_mutex wake (fun () -> Atomic.get asked) in
              Log.Transport.info "browser-host: %s received; %s" (signal_name signal)
                (match signal with
                 | Interrupt ->
                   "finishing the request in hand and ending the BiDi session. A second one ends \
                    the host at once and leaves that session in Firefox"
                 | Terminate | Hangup -> "finishing the request in hand and ending the BiDi session");
              signal_name signal))
      with Eio.Io _ -> Error "native messaging connection failed"
  in
  match result with
  | Ok () -> ()
  | Error detail -> Log.Transport.error "browser-host: %s" detail; exit 1
