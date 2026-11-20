type t = {
  mutable owned_server : Masc_tui_server_lifecycle.owned_server option;
  settled_starts : Masc_tui_server_lifecycle.settled_starts;
  mutable auto_start_spent : bool;
  mutable credential_retry_pending : bool;
}

let create () =
  { owned_server = None
  ; settled_starts = Masc_tui_server_lifecycle.create_settled_starts ()
  ; auto_start_spent = false
  ; credential_retry_pending = false
  }

let spend_auto_start t = t.auto_start_spent <- true
let set_credential_retry_pending t pending = t.credential_retry_pending <- pending

let launch_credential_preparation (state : Masc_tui_types.state) ~purpose
    ~base_path ~host ~port =
  let module Preparation = Masc_tui_credential_preparation in
  ignore
    (Preparation.start state.credential_preparation
       ~sw:(Eio_context.get_switch_opt ()) ~purpose ~base_path ~host ~port
       ~install:(fun () ->
         Masc_tui_http.install_operator_token ~base_path ~host ~port)
     : Preparation.request option)

let find_executable_in_path name =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path ->
      String.split_on_char ':' path
      |> List.find_map (fun dir ->
             if String.equal dir "" then None
             else
               let candidate = Filename.concat dir name in
               if Sys.file_exists candidate then Some candidate else None)

let server_output_location ~port
    (output : Masc_tui_server_lifecycle.startup_output) =
  match output with
  | Masc_tui_server_lifecycle.Written_to _ ->
      "full output: " ^ Masc_tui_server_lifecycle.startup_output_file ~port
  | Masc_tui_server_lifecycle.Not_kept _ ->
      Masc_tui_server_lifecycle.describe_output output

let note_server_exit ~note ~port (report : Masc_tui_server_lifecycle.exit_report) =
  note
    (Printf.sprintf "masc server exited (%s) before it was ready" report.status);
  note (Masc_tui_server_lifecycle.describe_last_line report.last_line);
  note (server_output_location ~port report.output)

let start_here t ~base_path ~host ~port ~note =
  (match t.owned_server with
   | Some server when not (Masc_tui_server_lifecycle.is_running server) ->
       t.owned_server <- None
   | Some _ | None -> ());
  match t.owned_server with
  | Some server ->
      note
        (Printf.sprintf "masc background server is already running (PID %d)"
           (Masc_tui_server_lifecycle.owned_pgid server))
  | None -> (
      match
        Masc_tui_server_lifecycle.discover_server_binary
          ~tui_exe:Sys.executable_name ~file_exists:Sys.file_exists
          ~path_lookup:find_executable_in_path ~base_path ~host ~port
      with
      | Masc_tui_server_lifecycle.Not_found { manual_command } ->
          note ("masc server binary not found; start it with: " ^ manual_command)
      | Masc_tui_server_lifecycle.Sibling masc_bin
      | Masc_tui_server_lifecycle.On_path masc_bin -> (
          match
            Masc_tui_server_lifecycle.start ~masc_bin ~base_path ~host ~port
              ~env:(Unix.environment ())
          with
          | Error e -> note ("masc server start failed: " ^ e)
          | Ok owned -> (
              t.owned_server <- Some owned;
              note "starting masc server here";
              match Eio_context.get_switch_opt () with
              | None -> ()
              | Some sw ->
                  Eio.Fiber.fork ~sw (fun () ->
                      let health_ok () =
                        match
                          Masc_tui_http.http_get ~host ~port
                            ~path:Server_health_paths.liveness
                        with
                        | Ok (200, _) -> true
                        | Ok _ | Error _ -> false
                      in
                      let sleep () =
                        match Eio_context.get_clock_opt () with
                        | Some clock -> Eio.Time.sleep clock 0.5
                        | None -> ()
                      in
                      Masc_tui_server_lifecycle.await_start t.settled_starts
                        owned ~host ~port ~health_ok ~attempts:60 ~sleep))))

let contact_of_connection_status :
    Masc_tui_types.connection_status -> Masc_tui_server_lifecycle.contact =
  function
  | Masc_tui_types.Disconnected -> Masc_tui_server_lifecycle.Nothing_answered
  | Masc_tui_types.Connected | Masc_tui_types.Degraded
  | Masc_tui_types.Account_server _ -> Masc_tui_server_lifecycle.Server_reached
  | Masc_tui_types.Connecting | Masc_tui_types.Booting ->
      Masc_tui_server_lifecycle.Undecided

let start_here_then_read t state ~base_path ~host ~port =
  start_here t ~base_path ~host ~port ~note:(fun msg ->
      Masc_tui_loader.add_event state "system" msg)

let apply_settled_starts t (state : Masc_tui_types.state) ~on_server_ready =
  let note msg = Masc_tui_loader.add_event state "system" msg in
  List.fold_left
    (fun said (settled : Masc_tui_server_lifecycle.settled_start) ->
      let host = settled.host and port = settled.port in
      if not (Option.fold ~none:false ~some:(fun current -> current == settled.server) t.owned_server) then
        said
      else begin
        (match settled.outcome with
         | Masc_tui_server_lifecycle.Ready ->
             note
               (Printf.sprintf
                  "masc background server is up (PID %d); it stays running when the TUI closes"
                  (Masc_tui_server_lifecycle.owned_pgid settled.server));
             state.refresh_pace <-
               Masc_tui_refresh_pace.answered_again state.refresh_pace;
             on_server_ready ~host ~port
         | Masc_tui_server_lifecycle.Server_exited report ->
             t.owned_server <- None;
             note_server_exit ~note ~port report
         | Masc_tui_server_lifecycle.Timed_out _ ->
             note
               (server_output_location ~port
                  (Masc_tui_server_lifecycle.startup_output settled.server));
             note "masc server did not answer /health in time");
        true
      end)
    false
    (Masc_tui_server_lifecycle.take_settled t.settled_starts)

(* What a refresh completing owes the operator, decided from the status it
   concluded rather than from which message carried it.

   Both reactions used to hang off [Http_refresh_failed], which carries an
   exception a surface load threw. Nothing listening on the port is not that:
   each surface returns its own connection error, the refresh completes, and
   [apply_http_surfaces] concludes [Disconnected] from the results. So the
   one case a first install produces reached neither the server start the
   installer promises nor a second look at a credential that could not be
   minted yet. *)
let react_to_contact t (state : Masc_tui_types.state) ~base_path ~host ~port =
  let contact = contact_of_connection_status state.connection_status in
  if
    Masc_tui_server_lifecycle.start_due ~contact
      ~already_attempted:t.auto_start_spent
  then begin
    t.auto_start_spent <- true;
    start_here_then_read t state ~base_path ~host ~port
  end;
  (* A server answering here is the workspace appearing. The decision is the
     same guarded one taken at boot -- it still refuses a base path that holds
     no workspace, so a server reached on some other path changes nothing --
     taken again at the moment its precondition can hold. It stays pending
     while it keeps failing, because the server that would settle it may be
     the one this session is still starting. *)
  if t.credential_retry_pending && contact = Masc_tui_server_lifecycle.Server_reached then
    launch_credential_preparation state
      ~purpose:Masc_tui_credential_preparation.Workspace_retry ~base_path ~host
      ~port;
  (* The start-up settings read failed, typically because the server this
     session starts itself was not up yet. It is read once more, when the
     server reached is this workspace's and this terminal's credential is
     no longer being retried: a read either of those would refuse is not
     spent. *)
  match state.settings_reread with
  | Masc_tui_types.Reread_due
    when contact = Masc_tui_server_lifecycle.Server_reached
         && state.workspace_identity = Masc_tui_types.Workspace_identity_match
         && not t.credential_retry_pending -> (
      match Eio_context.get_switch_opt () with
      | Some sw ->
          (* The loop peeks this promise in its drain, so the bell says when
             there is something to see. *)
          state.settings_reread <-
            Masc_tui_types.Reread_running
              (Eio.Fiber.fork_promise ~sw (fun () ->
                   Fun.protect
                     ~finally:(fun () ->
                       Masc_tui_wake.(ring loop Settings_reread))
                     state.preference_read))
      | None ->
          state.settings_reread <- Masc_tui_types.Reread_settled;
          Masc_tui_loader.report_action state "error"
            (Masc_tui_types.ui_text state
               ~ko:"화면 설정을 다시 읽을 수 없어요. 이번 세션은 기본값이에요."
               ~en:"Screen settings cannot be read again; this session stays on the defaults."))
  | Masc_tui_types.Reread_due | Masc_tui_types.Reread_settled
  | Masc_tui_types.Reread_running _ -> ()
