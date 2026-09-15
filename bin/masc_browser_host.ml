(** Firefox native messaging host: the command line of {!Browser_host}. *)

let ( let* ) = Result.bind

let () =
  Log.init_from_env ();
  let base_path = ref None and server = ref None and token_file = ref None and bidi_url = ref None in
  let positional = ref [] in
  let set target value = target := Some value in
  let options =
    [ "--bidi-url", Arg.String (set bidi_url), "URL Attach to an explicitly enabled loopback Firefox BiDi endpoint"
    ; "--base-path", Arg.String (set base_path), "PATH Workspace containing .masc (or MASC_BASE_PATH)"
    ; "--server", Arg.String (set server), "URL MASC HTTP server (or existing MASC HTTP configuration)"
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
      try Eio_main.run (fun env -> match !bidi_url with
        | None -> Browser_host.run env config
        | Some url -> Browser_host.run_bidi env config url)
      with Eio.Io _ -> Error "native messaging connection failed"
  in
  match result with
  | Ok () -> ()
  | Error detail -> Log.Transport.error "browser-host: %s" detail; exit 1
