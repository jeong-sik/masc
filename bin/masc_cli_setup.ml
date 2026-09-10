(** Local first-run orchestration. The existing init, image builder, login and
    Keeper up handlers remain the owners of their respective state changes. *)
exception Setup_error of string

let fail message = raise (Setup_error message)

type workspace_issue_kind = Invalid_state | Unreadable_state

type workspace_issue = { path : string; kind : workspace_issue_kind; detail : string }

type workspace_preflight = Workspace_ready | Workspace_needs_attention of workspace_issue list

let validate_json validate body =
  match Yojson.Safe.from_string body with
  | json -> validate json
  | exception Yojson.Json_error detail -> Error detail

let validate_run_log body =
  if String.length body > 0 && body.[String.length body - 1] <> '\n' then
    Error "Incomplete JSONL tail: the final event must end with a newline"
  else List.mapi (fun index line -> index + 1, line) (String.split_on_char '\n' body)
  |> List.fold_left (fun result (line_number, line) ->
    Result.bind result (fun () ->
      if String.trim line = "" then Ok () else
        validate_json Masc.Goal_verification_run_registry.validate_event_json line
        |> Result.map_error (fun detail -> Printf.sprintf "line %d: %s" line_number detail))) (Ok ())

let validate_keeper_profile ~path body =
  Masc.Keeper_types_profile.materialization_defaults_of_content ~path body
  |> Result.map (fun _ -> ())
  |> Result.map_error Masc.Keeper_types_profile.keeper_toml_load_error_to_string

let preflight_base_path base_path =
  let normalized = Env_config.normalize_masc_base_path_input base_path in
  if Filename.is_relative normalized then Filename.concat (Sys.getcwd ()) normalized else normalized

let workspace_preflight_at_root ~root =
  let check path validate =
    let present = try let (_ : Unix.stats) = Unix.lstat path in Ok true with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
      | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error) in
    match present with
    | Ok false -> []
    | Error detail -> [{path; kind = Unreadable_state; detail}]
    | Ok true -> match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path with
    | Ok None -> []
    | Error _ -> [{path; kind = Unreadable_state;
        detail = "Cannot read an owned regular state file. Check the path, permissions and symlinks; no file was changed."}]
    | Ok (Some snapshot) ->
      (match validate snapshot.content with
       | Ok () -> []
       | Error detail -> [{path; kind = Invalid_state; detail}])
  in
  let directory = Filename.concat root "config/keepers" in
  let keeper_issues =
    match Unix.opendir directory with
    | handle ->
      let names = Fun.protect ~finally:(fun () -> Unix.closedir handle) (fun () ->
        let rec collect acc = match Unix.readdir handle with
          | name -> collect (name :: acc)
          | exception End_of_file -> acc in
        collect []) in
      names |> List.sort String.compare
      |> List.filter (fun name -> Filename.check_suffix name ".toml")
      |> List.concat_map (fun name -> let path = Filename.concat directory name in
        check path (validate_keeper_profile ~path))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
    | exception Unix.Unix_error (error, _, _) ->
      [{path = directory; kind = Unreadable_state; detail = Unix.error_message error}]
  in
  let stores = ["goals.json", validate_json Goal_store.validate_state_json;
                "goal_verifications.json", validate_json Goal_verification.validate_state_json;
                Masc.Goal_verification_run_registry.storage_filename, validate_run_log] in
  let store_issues = List.concat_map (fun (name, validate) ->
    let path = Filename.concat root name in
    let mirror = path ^ ".last-good" in
    let missing_primary =
      if not (Sys.file_exists path) && Sys.file_exists mirror then
        [{path; kind = Unreadable_state;
          detail = "The primary state file is missing but its recovery mirror exists. Choose a new workspace or review the original state; setup will not restore it automatically."}]
      else [] in
    missing_primary @ check path validate @ check mirror validate) stores in
  match keeper_issues @ store_issues with
  | [] -> Workspace_ready
  | issues -> Workspace_needs_attention issues

let workspace_preflight ~base_path =
  let requested_root = Filename.concat (preflight_base_path base_path) Common.masc_dirname in
  (* Deployment may link .masc to a volume. Resolve that root once, then apply
     owned-child checks below the physical root rather than through the link. *)
  let unreadable detail = Workspace_needs_attention
    [{path = requested_root; kind = Unreadable_state; detail}] in
  try
    let present =
      try let (_ : Unix.stats) = Unix.lstat requested_root in true
      with Unix.Unix_error (Unix.ENOENT, _, _) -> false
    in
    if not present then Workspace_ready
    else
      let root = Fs_compat.realpath requested_root in
      let before = Unix.stat root in
      if before.Unix.st_kind <> Unix.S_DIR then unreadable "MASC root is not a directory"
      else
        let result = workspace_preflight_at_root ~root in
        let after = Unix.stat root in
        if before.Unix.st_dev = after.Unix.st_dev && before.Unix.st_ino = after.Unix.st_ino
           && String.equal root (Fs_compat.realpath requested_root)
        then result
        else unreadable "MASC root changed during preflight; no file was changed"
  with
  | Unix.Unix_error (error, _, _) -> unreadable (Unix.error_message error)
  | Sys_error detail -> unreadable detail

let workspace_preflight_json ~base_path preflight =
  let status, issues = match preflight with
    | Workspace_ready -> "ready", []
    | Workspace_needs_attention issues -> "needs_attention", issues in
  `Assoc ["status", `String status; "read_only", `Bool true;
    "scope", `String "keeper_goal_state_schema";
    "base_path", `String (preflight_base_path base_path);
    "issues", `List (List.map (fun issue -> `Assoc [
      "path", `String issue.path;
      "kind", `String (match issue.kind with Invalid_state -> "invalid_state" | Unreadable_state -> "unreadable_state");
      "detail", `String issue.detail]) issues);
    "actions", `List (List.map (fun name -> `String name)
      (match preflight with Workspace_ready -> [] | Workspace_needs_attention _ ->
        ["choose_new_workspace"; "return_without_changes"]))]

let preflight_cmd_exit base_path =
  let preflight = workspace_preflight ~base_path in
  print_endline (Yojson.Safe.to_string (workspace_preflight_json ~base_path preflight));
  match preflight with Workspace_ready -> 0 | Workspace_needs_attention _ -> 1

let require_compatible_workspace base_path =
  match workspace_preflight ~base_path with
  | Workspace_ready -> ()
  | Workspace_needs_attention issues as preflight ->
    prerr_endline (Yojson.Safe.to_string (workspace_preflight_json ~base_path preflight));
    let paths = String.concat ", " (List.map (fun issue -> issue.path) issues) in
    fail (Printf.sprintf
      "Workspace state needs attention: %s. No workspace files were changed and no server was started. Choose an unused directory with masc setup --base-path NEW_WORKSPACE, or return without changes and review these files before retrying. Existing logs: %s"
      paths (Filename.concat (Filename.concat base_path Common.masc_dirname) "logs"))

(* Waiting belongs to the PID already spawned. EINTR only interrupts the
   syscall: it must not rerun the command or turn a successful build into a
   setup failure. Both direct setup children and image-builder callbacks use
   this same wait boundary. Other wait errors remain visible to the caller. *)
let rec wait_for_child pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child pid

let run_process argv =
  match argv with
  | [] -> invalid_arg "setup process needs argv"
  | program :: _ ->
    let pid = Unix.create_process program (Array.of_list argv)
        Unix.stdin Unix.stdout Unix.stderr in
    match wait_for_child pid with
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
        require_compatible_workspace base_path;
        require_ok "Workspace initialization" initialize;
        let base_path = Unix.realpath base_path in
        Printf.printf "Preparing imp in %s\n%!" base_path;
        require_ok "Model validation" validate_runtime;
        (* A reused port is checked before credentials or Keeper state change. *)
        require_ok "Docker (install and start Docker Desktop on macOS, or Docker Engine on Linux)"
          (fun () ->
            try run_process [ "docker"; "info"; "--format"; "{{.OSType}}" ] with
            | Unix.Unix_error (Unix.ENOENT, _, _) ->
              prerr_endline "The docker executable was not found on PATH.";
              if Executable_path.command_available "container" then
                prerr_endline
                  "Apple Container is installed; Keepers on the microvm \
                   profile can use it, but imp's default profile needs \
                   Docker (see docs/INSTALL.md)."
              else
                prerr_endline
                  "On Apple Silicon with macOS 26+, Apple Container is a \
                   separate supported runtime for Keepers on the microvm \
                   profile; imp's default profile still requires Docker \
                   (see docs/INSTALL.md).";
              1);
        require_ok "Sandbox image preparation" prepare_image;
        prepare_server ~base_path ~port ~owned;
        require_ok "Local operator sign-in" login;
        require_ok "Starting imp" start_keeper;
        Printf.printf "\nimp is started. Send your first message to begin the conversation.\n\
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
