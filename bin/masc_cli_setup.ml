(** Local first-run orchestration. The existing init, image builder, login and
    Keeper up handlers remain the owners of their respective state changes. *)
exception Setup_error of string

let fail message = raise (Setup_error message)

let run_process argv =
  match argv with
  | [] -> invalid_arg "setup process needs argv"
  | program :: _ ->
    let pid = Unix.create_process program (Array.of_list argv)
        Unix.stdin Unix.stdout Unix.stderr in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 1

let require_ok label action =
  if action () <> 0 then fail (label ^ " failed; fix the diagnostic above and run setup again.")

let field key json =
  match json with `Assoc fields -> List.assoc_opt key fields | _ -> None

let health_state ~base_path body =
  let json =
    try Yojson.Safe.from_string body
    with Yojson.Json_error message -> fail ("The selected port did not return MASC health JSON: " ^ message)
  in
  match Option.bind (field "paths" json) (field "effective_base_path") with
  | Some (`String actual) when String.equal (Unix.realpath actual) base_path ->
    Option.bind (field "startup" json) (field "state_ready") = Some (`Bool true)
  | Some (`String actual) ->
    fail (Printf.sprintf "Port belongs to workspace %s, not %s. Use --port with an unused port." actual base_path)
  | _ -> fail "The selected port has no workspace identity; use an unused --port."

let prepare_server ~base_path ~port ~owned =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        let clock = Eio.Stdenv.clock env in
        let read () =
          Masc_http_client.get_sync ~clock
            ~url:(Printf.sprintf "http://127.0.0.1:%d/health?full=1" port)
            ~headers:[] ()
        in
        let initial = read () in
        (match initial with
         (* See the readiness wait below: this first read validates ownership even while state is loading. *)
         | Ok (200, body) -> ignore (health_state ~base_path body)
         | Ok (status, _) -> fail (Printf.sprintf "Port %d returned HTTP %d; choose an unused --port." port status)
         | Error _ ->
           (match Masc_tui_server_lifecycle.start
                    ~masc_bin:Sys.executable_name ~base_path ~host:"127.0.0.1" ~port
                    ~env:(Unix.environment ()) with
            | Error message -> fail message
            | Ok server -> owned := Some server));
        (* Startup is a bounded resource operation, not a Keeper turn budget. *)
        match Eio.Time.with_timeout clock 60.0 (fun () ->
          let rec wait () =
            (match !owned with
             | Some server when not (Masc_tui_server_lifecycle.is_running server) ->
               fail ("Server exited; inspect " ^ base_path ^ "/.masc/logs and rerun setup.")
             | _ -> ());
            match read () with
            | Ok (200, body) when health_state ~base_path body -> Ok ()
            | Ok (status, _) when status <> 200 ->
              fail (Printf.sprintf "Server readiness returned HTTP %d." status)
            | _ -> Eio.Time.sleep clock 0.2; wait ()
          in wait ()) with
        | Ok () -> ()
        | Error `Timeout -> fail "Server is not ready yet; inspect its logs and rerun setup.")))

let run ~base_path ~port ~initialize ~prepare_image ~validate_runtime ~login ~start_keeper ~open_tui =
  let owned = ref None in
  Fun.protect
    ~finally:(fun () ->
      match !owned with
      | None -> ()
      | Some server -> Masc_tui_server_lifecycle.stop server ~grace_sec:5.0)
    (fun () ->
      try
        if not (Unix.isatty Unix.stdin) && open_tui then
          fail "Interactive setup needs a terminal. Use --no-tui to prepare imp without opening the terminal UI.";
        require_ok "Workspace initialization" initialize;
        let base_path = Unix.realpath base_path in
        Printf.printf "Preparing imp in %s\n%!" base_path;
        require_ok "Model connection" validate_runtime;
        (* A reused port is checked before credentials or Keeper state change. *)
        require_ok "Docker (install and start Docker Desktop on macOS, or Docker Engine on Linux)"
          (fun () -> run_process ["docker"; "info"; "--format"; "{{.OSType}}"]);
        require_ok "Sandbox image preparation" prepare_image;
        prepare_server ~base_path ~port ~owned;
        require_ok "Local operator sign-in" login;
        require_ok "Starting imp" start_keeper;
        Printf.printf "\nimp is started. Model replies are verified by your first conversation.\n\
          Keepers: select imp, open its chat, and say hello. Then ask it to create a Board post\n\
          and a Task, list its sandbox directory, and fetch https://example.com.\n\
          If a tool asks permission, answer in the chat.\n%!";
        if open_tui then (
          let is_executable path =
            try Unix.access path [Unix.X_OK]; true
            with Unix.Unix_error _ -> false
          in
          match Masc_front_door.decide ~interactive:true ~host:"127.0.0.1"
            ~default_host:"127.0.0.1" ~deployment_flags_present:false ~port
            ~base_path:(Some base_path) ~executable_name:Sys.argv.(0)
            ~path_env:(Sys.getenv_opt "PATH") ~is_executable with
          | Masc_front_door.Open_tui { argv; _ } ->
            require_ok "Terminal UI" (fun () -> run_process argv)
          | Masc_front_door.Serve ->
            fail "masc-tui is missing beside masc and from PATH. Add the installation prefix to PATH and rerun setup.")
        else (
          (* Explicit headless setup keeps its server running for the caller. *)
          owned := None;
          Printf.printf "Server remains on http://127.0.0.1:%d. Open masc --base-path %s --port %d\n%!"
            port (Filename.quote base_path) port);
        0
      with
      | Setup_error message -> Log.Misc.error "setup: %s" message; 1
      | Unix.Unix_error (error, operation, path) ->
        Log.Misc.error "setup: %s %s: %s" operation path (Unix.error_message error); 1)
