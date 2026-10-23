module Sandbox = Masc.Sandbox_readiness
module Prerequisites = Masc.Sandbox_prerequisites
module Apple = Masc.Apple_container_install
module Docker = Masc.Docker_desktop_install
type action = Standard of Prerequisites.action | Verified_apple_install
  | Verified_docker_install | Verified_docker_launch
(* The SearXNG settings directory is host-global: the container name and the
   published port are global, so a per-workspace directory would leave a
   second workspace starting the first one's container, with the first one's
   key (#43181 item 6). The chain matches scripts/searxng-local.sh: an
   explicit directory, the XDG data home, $HOME/.local/share, and finally
   this workspace's directory when the host names no home at all. *)
let searxng_config_dir ~base_path () =
  let nonempty = function
    | Some value when String.trim value <> "" -> Some (String.trim value)
    | _ -> None in
  let explicit = nonempty (Sys.getenv_opt "MASC_SEARXNG_CONFIG_DIR") in
  let under_data_home data_home = Filename.concat data_home "masc-searxng" in
  let xdg = Option.map under_data_home (nonempty (Sys.getenv_opt "XDG_DATA_HOME")) in
  let home =
    Option.map
      (fun home -> under_data_home (Filename.concat home ".local/share"))
      (nonempty (Sys.getenv_opt "HOME")) in
  match explicit, xdg, home with
  | Some dir, _, _ | None, Some dir, _ | None, None, Some dir -> dir
  | None, None, None ->
    let base_path = Env_config.normalize_masc_base_path_input (base_path ()) in
    Filename.concat (Common.masc_dir_from_base_path ~base_path) Common.searxng_dirname
let dependency ~base_path = function
  | "codex" -> Some Prerequisites.Codex_cli
  | "claude-code" -> Some Prerequisites.Claude_cli
  | "antigravity" -> Some Prerequisites.Antigravity_cli
  | "muse-code" -> Some Prerequisites.Muse_cli
  | "pdf-tools" -> Some Prerequisites.Pdf_tools
  | "presentation-tools" ->
    Some (Prerequisites.Presentation_tools
            { base_path = Env_config.normalize_masc_base_path_input (base_path ()) })
  | "whisper" -> Some Prerequisites.Whisper_cli
  | "geckodriver" -> Some Prerequisites.Geckodriver
  | "firefox" -> Some Prerequisites.Firefox
  | "ego-browser" -> Some Prerequisites.Ego_browser
  | "searxng" ->
    Some (Prerequisites.Searxng { config_dir = searxng_config_dir ~base_path () })
  | name -> Option.map (fun backend -> Prerequisites.Sandbox backend) (Sandbox.backend_of_id name)

(* Where a downloaded model lands. A cache directory rather than anywhere under
   masc: the file is whisper's, masc only names its path in the configuration,
   and nothing here deletes or refreshes it. Absent HOME, the catalog opens the
   downloads page instead of offering a command with nowhere to write. *)
let model_dir () =
  Option.map
    (fun home -> Filename.concat (Filename.concat home ".cache") "whisper")
    (Sys.getenv_opt "HOME")
(* Where Apple Container reads a user's settings: $XDG_CONFIG_HOME/container,
   else ~/.config/container (apple/container PathUtils.BaseConfigPath.home,
   1.3.1 and 1.4.1). Absent both, building without Rosetta has nowhere to be
   recorded, and only installing Rosetta is offered. *)
let container_user_config () =
  let base = match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some xdg when not (String.equal xdg "") -> Some xdg
    | Some _ | None -> Option.map (fun home -> Filename.concat home ".config") (Sys.getenv_opt "HOME") in
  Option.map (fun base -> Filename.concat (Filename.concat base "container") "config.toml") base
(* A service that is absent or stopped keeps its installers and start action,
   whatever Rosetta says; see [Sandbox_readiness.apple_container_needs_rosetta].
   Rosetta is asked first: a builder that cannot start never reaches a kernel.
   A builder that starts but has no default kernel gets its own action, so the
   readiness answer and the offered fix name the same missing piece. *)
let apple_builder host dependency =
  match host, dependency with
  | Sandbox.Macos {architecture=Arm64; major}, Prerequisites.Sandbox Apple_container
    when major >= 26 && Sandbox.apple_container_needs_rosetta ~run:Sandbox.system_runner ->
    Prerequisites.Needs_missing_rosetta {user_config=container_user_config ()}
  | Sandbox.Macos {architecture=Arm64; major}, Prerequisites.Sandbox Apple_container
    when major >= 26 && Sandbox.apple_container_needs_default_kernel ~run:Sandbox.system_runner ->
    Prerequisites.Needs_default_kernel
  | ( Sandbox.Macos {architecture=(Arm64 | X64); _} | Sandbox.Linux _ | Sandbox.Unsupported ),
    ( Prerequisites.Sandbox (Docker | Apple_container | Nerdctl_kata | Microsandbox | Remote_ssh)
    | Prerequisites.Codex_cli | Prerequisites.Claude_cli | Prerequisites.Antigravity_cli
    | Prerequisites.Muse_cli | Prerequisites.Pdf_tools | Prerequisites.Presentation_tools _
    | Prerequisites.Whisper_cli | Prerequisites.Geckodriver | Prerequisites.Firefox
    | Prerequisites.Ego_browser | Prerequisites.Searxng _ )
    -> Prerequisites.Builder_unchecked
let rec wait pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> Ok ()
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Error ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid
let run_terminal = function
  | [] -> Error ()
  | executable :: _ as argv ->
    try Unix.create_process executable (Array.of_list argv) Unix.stdin Unix.stderr Unix.stderr |> wait
    with Unix.Unix_error _ -> Error ()
(* [run_terminal] for a catalog step, keeping which way it failed. Only the
   kind crosses into the receipt; the child's own output went to the terminal
   and stays there. [create_process] searches PATH and raises ENOENT when the
   program is not on it, before anything runs. *)
let run_catalog_step = function
  | [] -> Error Prerequisites.Could_not_start
  | executable :: _ as argv ->
    (match Unix.create_process executable (Array.of_list argv) Unix.stdin Unix.stderr Unix.stderr with
     | pid -> Result.map_error (fun () -> Prerequisites.Did_not_finish) (wait pid)
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error Prerequisites.Program_not_found
     | exception Unix.Unix_error (_, _, _) -> Error Prerequisites.Could_not_start)
let capture argv =
  match Process_eio.run_argv_with_status_split_or_refusal argv with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) | Error _ -> Error ()
let id = function Standard action -> action.Prerequisites.id
  | Verified_apple_install -> "apple_container_verified_install"
  | Verified_docker_install -> "docker_desktop_verified_install"
  | Verified_docker_launch -> "docker_desktop_verified_launch"
let actions ?searxng_container host dependency =
  let distribution = try
    In_channel.with_open_text "/etc/os-release" In_channel.input_all
    |> Prerequisites.distribution_of_os_release
    with Sys_error _ -> Prerequisites.Other in
  let apple_builder = apple_builder host dependency in
  (* Docker is asked only for the dependency that is a container, and not
     again when the caller already looked. *)
  let searxng_container = match dependency, searxng_container with
    | Prerequisites.Searxng _, Some container -> container
    | Prerequisites.Searxng _, None -> Masc.Searxng_runtime_dependency.container ()
    | (Prerequisites.Sandbox _ | Prerequisites.Codex_cli | Prerequisites.Claude_cli
      | Prerequisites.Antigravity_cli | Prerequisites.Muse_cli | Prerequisites.Pdf_tools
      | Prerequisites.Presentation_tools _ | Prerequisites.Whisper_cli | Prerequisites.Geckodriver
      | Prerequisites.Firefox | Prerequisites.Ego_browser), _ -> Prerequisites.Searxng_absent in
  let standard =
    Prerequisites.catalog ?model_dir:(model_dir ()) ~apple_builder ~searxng_container ~host ~distribution dependency
    |> List.map (fun action -> Standard action)
  in
  match host, dependency with
  | Sandbox.Macos {architecture=Arm64; major}, Prerequisites.Sandbox Apple_container when major >= 26 ->
    (match apple_builder with
     | Prerequisites.Needs_missing_rosetta _ | Prerequisites.Needs_default_kernel -> standard
     | Prerequisites.Builder_unchecked -> Verified_apple_install :: standard)
  | Sandbox.Macos _, Prerequisites.Sandbox Docker ->
    Verified_docker_install :: Verified_docker_launch :: standard
  | (Sandbox.Macos { architecture = Sandbox.Arm64; major = _ }, Prerequisites.Sandbox (Sandbox.Nerdctl_kata | (Sandbox.Microsandbox | Sandbox.Remote_ssh)))
  | (Sandbox.Macos { architecture = Sandbox.Arm64; major = _ }, (Prerequisites.Codex_cli | (Prerequisites.Claude_cli | (Prerequisites.Antigravity_cli | (Prerequisites.Muse_cli | (Prerequisites.Pdf_tools | (Prerequisites.Whisper_cli | Prerequisites.Presentation_tools _ | Prerequisites.Geckodriver | Prerequisites.Firefox | Prerequisites.Ego_browser)))))))
  | (Sandbox.Macos { architecture = Sandbox.X64; major = _ }, Prerequisites.Sandbox (Sandbox.Apple_container | (Sandbox.Nerdctl_kata | (Sandbox.Microsandbox | Sandbox.Remote_ssh))))
  | (Sandbox.Macos { architecture = Sandbox.X64; major = _ }, (Prerequisites.Codex_cli | (Prerequisites.Claude_cli | (Prerequisites.Antigravity_cli | (Prerequisites.Muse_cli | (Prerequisites.Pdf_tools | (Prerequisites.Whisper_cli | Prerequisites.Presentation_tools _ | Prerequisites.Geckodriver | Prerequisites.Firefox | Prerequisites.Ego_browser)))))))
  | ((Sandbox.Unsupported | Sandbox.Linux _), _)
  | (Sandbox.Macos _, Prerequisites.Searxng _)
  | (Macos {architecture=Arm64; _ }, Sandbox Apple_container) -> standard
let to_json actions =
  let standard = List.filter_map (function Standard action -> Some action
    | Verified_apple_install | Verified_docker_install | Verified_docker_launch -> None) actions in
  let json = Prerequisites.to_json standard in
  let custom = List.filter_map (fun action ->
    let description = match action with
      | Standard _ -> None
      | Verified_apple_install -> Some ("Install Apple Container (verify the signed package)",
        "Download Apple's signed package, check its digest and publisher, then open the administrator installation step. Service and guest checks follow separately.",
        "https://github.com/apple/container/releases/latest", true, "verified_package_install")
      | Verified_docker_install -> Some ("Install Docker Desktop (verify the official installer)",
        "Download Docker's official installer, verify its checksum and publisher, then install with administrator access. Docker presents its own license and startup steps when you open it.",
        "https://docs.docker.com/desktop/setup/install/mac-install/", true, "verified_package_install")
      | Verified_docker_launch -> Some ("Open Docker Desktop and complete its startup steps",
        "Verify the installed Docker app and open it. Complete Docker's license or account prompts, then refresh setup to check engine access.",
        "https://docs.docker.com/desktop/setup/install/mac-install/", false, "vendor_startup") in
    Option.map (fun (label, detail, source_url, requires_admin, kind) -> `Assoc [
      "id", `String (id action); "label", `String label; "detail", `String detail;
      "source_url", `String source_url; "requires_admin", `Bool requires_admin;
      "effect", `Assoc ["kind", `String kind]; "completion", `String "recheck_required"]) description) actions in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "actions" fields with
     | Some (`List rows) -> `Assoc (("actions", `List (custom @ rows)) :: List.remove_assoc "actions" fields)
     | _ -> json)
  | json -> json
let execute host = function
  | Standard action ->
    Prerequisites.execute ~run:run_catalog_step action
  | Verified_apple_install ->
    prerr_endline "Downloading and verifying the official Apple Container package…";
    (match Apple.acquire ~host ~run:capture with
     | Error error -> Prerequisites.Failed {step=1; reason=Apple.error_message error}
     | Ok artifact ->
       Fun.protect ~finally:(fun () -> Apple.remove artifact) (fun () ->
         prerr_endline "Package verified. The administrator installer may request your password.";
         match Apple.install ~executable_path:Sys.executable_name
                 ~run:capture ~elevate:run_terminal artifact with
         | Ok () -> Prerequisites.Commands_completed_recheck_required
         | Error error -> Prerequisites.Failed {step=2; reason=Apple.error_message error}))
  | Verified_docker_install ->
    prerr_endline "Downloading and verifying the official Docker Desktop installer…";
    (match Docker.acquire ~host ~run:capture with
     | Error error -> Prerequisites.Failed {step=1; reason=Docker.error_message error}
     | Ok artifact -> Fun.protect ~finally:(fun () -> Docker.remove artifact) (fun () ->
       match Docker.install ~host ~executable_path:Sys.executable_name ~run:Masc.Prerequisite_terminal_runner.capture
         ~probe_run:Sandbox.system_runner
         ~require_rootless:(Env_config_sandbox.Hardening.require_rootless ())
         ~require_userns:(Env_config_sandbox.Hardening.require_userns ()) artifact with
       | Error error -> Prerequisites.Failed {step=2; reason=Docker.error_message error}
       | Ok result ->
         (match result.completion.cleanup with Docker.Cleaned -> ()
          | Pending directory -> Printf.eprintf "Installation completed; installer cleanup remains at %s.\n" directory);
         prerr_endline "Docker is installed. Choose Open Docker Desktop, complete its startup steps, then refresh detection.";
         Prerequisites.Commands_completed_recheck_required))
  | Verified_docker_launch ->
    (match Docker.launch_and_recheck ~host ~run:capture ~probe_run:Sandbox.system_runner
      ~require_rootless:(Env_config_sandbox.Hardening.require_rootless ())
      ~require_userns:(Env_config_sandbox.Hardening.require_userns ()) () with
     | Error error -> Prerequisites.Failed {step=1; reason=Docker.error_message error}
     | Ok _ -> Prerequisites.External_step_pending)
let browser_readiness program =
  Masc.Browser_runtime_dependencies.(to_json program (observe program))
(* Same shape as the PDF receipt: a completed install that left a program which
   does not start is a failure, not a success the next refresh will contradict. *)
let browser_receipt program receipt =
  let check = Masc.Browser_runtime_dependencies.observe program in
  let ready = Masc.Browser_runtime_dependencies.available check in
  let fields = match receipt with `Assoc fields -> fields
    | _ -> invalid_arg "prerequisite outcome encoder must return an object" in
  let fields = List.remove_assoc "readiness" fields in
  let fields = if ready then
    ("status",`String "commands_completed") :: List.remove_assoc "status" fields
  else
    ("status",`String "failed") ::
    ("reason",`String "Installation finished, but the program could not start. Inspect dependency_readiness, correct the installation or PATH, then refresh detection.") ::
    List.remove_assoc "status" fields in
  `Assoc (("readiness",`String (if ready then "tools_available" else "unavailable")) ::
    ("dependency_readiness",Masc.Browser_runtime_dependencies.to_json program check) :: fields),
  (if ready then 0 else 1)
(* A container that was started and does not answer JSON is not a prerequisite
   that is met: the receipt waits for it to listen, and says which of Docker,
   the container and the endpoint is the one that is not there. *)
let searxng_receipt receipt =
  let check = Masc.Searxng_runtime_dependency.wait_until_available () in
  let ready = Masc.Searxng_runtime_dependency.available check in
  let fields = match receipt with `Assoc fields -> fields
    | _ -> invalid_arg "prerequisite outcome encoder must return an object" in
  let fields = List.remove_assoc "readiness" fields in
  let fields = if ready then
    ("status",`String "commands_completed") :: List.remove_assoc "status" fields
  else
    ("status",`String "failed") ::
    ("reason",`String (Printf.sprintf "The steps finished, but SearXNG did not answer a JSON search at %s. Inspect dependency_readiness and `docker logs %s`, then refresh detection."
       Masc.Searxng_runtime_dependency.default_url Prerequisites.searxng_container_name)) ::
    List.remove_assoc "status" fields in
  `Assoc (("readiness",`String (if ready then "tools_available" else "unavailable")) ::
    ("dependency_readiness",Masc.Searxng_runtime_dependency.to_json check) :: fields),
  (if ready then 0 else 1)
let run ~base_path ~dependency:name ~action =
  match dependency ~base_path name with
  | None -> prerr_endline "Unknown prerequisite. Choose a dependency from the setup catalog."; 1
  | Some dependency ->
    let host = Sandbox.detect_host ~run:Sandbox.system_runner in
    (* Printing the catalog looks at Docker once, for the plan and for the
       readiness it carries. Executing an action asks only for the plan: its
       receipt looks again after the steps. *)
    let searxng_check = match dependency, action with
      | Prerequisites.Searxng _, None -> Some (Masc.Searxng_runtime_dependency.observe ())
      | (Prerequisites.Searxng _ | Prerequisites.Sandbox _ | Prerequisites.Codex_cli
        | Prerequisites.Claude_cli | Prerequisites.Antigravity_cli | Prerequisites.Muse_cli
        | Prerequisites.Pdf_tools | Prerequisites.Presentation_tools _ | Prerequisites.Whisper_cli
        | Prerequisites.Geckodriver | Prerequisites.Firefox | Prerequisites.Ego_browser), _ -> None in
    let actions =
      actions ?searxng_container:(Option.map (fun (check : Masc.Searxng_runtime_dependency.check) -> check.container) searxng_check)
        host dependency in
    match action with
    | None ->
      let catalog = to_json actions in
      let catalog = match dependency, catalog with
        | Prerequisites.Pdf_tools, `Assoc fields ->
          `Assoc (("dependency_readiness", Masc.Pdf_runtime_dependencies.(observe () |> to_json)) :: fields)
        | Prerequisites.Presentation_tools {base_path}, `Assoc fields ->
          `Assoc (("dependency_readiness", Masc.Presentation_runtime_dependencies.(observe ~base_path () |> to_json)) :: fields)
        | Prerequisites.Geckodriver, `Assoc fields ->
          `Assoc (("dependency_readiness",
                   browser_readiness Masc.Browser_runtime_dependencies.Geckodriver) :: fields)
        | Prerequisites.Firefox, `Assoc fields ->
          `Assoc (("dependency_readiness",
                   browser_readiness Masc.Browser_runtime_dependencies.Firefox) :: fields)
        | Prerequisites.Ego_browser, `Assoc fields ->
          `Assoc (("dependency_readiness",
                   browser_readiness Masc.Browser_runtime_dependencies.Ego_browser) :: fields)
        | Prerequisites.Searxng _, `Assoc fields ->
          let check = match searxng_check with
            | Some check -> check
            | None -> Masc.Searxng_runtime_dependency.observe () in
          `Assoc (("dependency_readiness", Masc.Searxng_runtime_dependency.to_json check) :: fields)
        | (Sandbox _ | Codex_cli | Claude_cli | Antigravity_cli | Muse_cli | Whisper_cli), _ -> catalog
        | (Pdf_tools | Presentation_tools _ | Geckodriver | Firefox | Ego_browser | Searxng _), _ ->
          invalid_arg "prerequisite catalog encoder must return an object" in
      print_endline (Yojson.Safe.to_string catalog); 0
    | Some requested ->
      (match List.find_opt (fun action -> id action = requested) actions with
       | None -> prerr_endline "This prerequisite action is not offered on the current host."; 1
       | Some action ->
         let outcome = execute host action in
         let receipt = Prerequisites.outcome_to_json outcome in
         let receipt, code = match dependency, outcome with
           | Prerequisites.Pdf_tools, Prerequisites.Commands_completed_recheck_required ->
             let checks = Masc.Pdf_runtime_dependencies.observe () in
             let ready = Masc.Pdf_runtime_dependencies.available checks in
             let fields = match receipt with `Assoc fields -> fields
               | _ -> invalid_arg "prerequisite outcome encoder must return an object" in
             let fields = List.remove_assoc "readiness" fields in
             let fields = if ready then
               ("status",`String "commands_completed") :: List.remove_assoc "status" fields
             else
               ("status",`String "failed") ::
               ("reason",`String "Installation finished, but PDF tools could not start. Inspect dependency_readiness, correct the installation or PATH, then refresh detection.") ::
               List.remove_assoc "status" fields in
             `Assoc (("readiness",`String (if ready then "tools_available" else "unavailable")) ::
               ("dependency_readiness",Masc.Pdf_runtime_dependencies.to_json checks) :: fields),
             (if ready then 0 else 1)
           | Prerequisites.Presentation_tools {base_path}, outcome ->
             let checks = Masc.Presentation_runtime_dependencies.observe ~base_path () in
             let ready = Masc.Presentation_runtime_dependencies.available checks in
             let selected_component_ready = match action with
               | Standard {id="presentation_parser_install"; _} ->
                 Masc.Presentation_runtime_dependencies.parser_available checks
               | Standard {id="poppler_install"; _} ->
                 Masc.Presentation_runtime_dependencies.pdf_available checks
               | Standard {id="presentation_renderer_install"; _} ->
                 Masc.Presentation_runtime_dependencies.renderer_available checks
               | Standard _ | Verified_apple_install | Verified_docker_install | Verified_docker_launch -> ready in
             let fields = match receipt with `Assoc fields -> fields
               | _ -> invalid_arg "prerequisite outcome encoder must return an object" in
             let fields = List.remove_assoc "readiness" fields in
             let fields = match outcome with
               | Prerequisites.Commands_completed_recheck_required when not selected_component_ready ->
                 ("status",`String "failed") ::
                 ("reason",`String "The selected installation commands finished, but that component did not start. Inspect dependency_readiness and correct the installation before refreshing detection.") ::
                 List.remove_assoc "status" fields
               | Prerequisites.Commands_completed_recheck_required when ready ->
                 ("status",`String "commands_completed") :: List.remove_assoc "status" fields
               | Prerequisites.Commands_completed_recheck_required | External_step_pending | Failed _ -> fields in
             `Assoc (("readiness",`String (if ready then "tools_available" else "unavailable")) ::
               ("dependency_readiness",Masc.Presentation_runtime_dependencies.to_json checks) :: fields),
             (match outcome with Prerequisites.Failed _ -> 1 | External_step_pending -> 0
              | Commands_completed_recheck_required -> if selected_component_ready then 0 else 1)
           | Prerequisites.Geckodriver, Prerequisites.Commands_completed_recheck_required ->
             browser_receipt Masc.Browser_runtime_dependencies.Geckodriver receipt
           | Prerequisites.Firefox, Prerequisites.Commands_completed_recheck_required ->
             browser_receipt Masc.Browser_runtime_dependencies.Firefox receipt
           | Prerequisites.Ego_browser, Prerequisites.Commands_completed_recheck_required ->
             browser_receipt Masc.Browser_runtime_dependencies.Ego_browser receipt
           | Prerequisites.Searxng _, Prerequisites.Commands_completed_recheck_required ->
             searxng_receipt receipt
           | (Prerequisites.Sandbox _, Prerequisites.Failed _)
           | (Prerequisites.Codex_cli, Prerequisites.Failed _)
           | (Prerequisites.Claude_cli, Prerequisites.Failed _)
           | (Prerequisites.Antigravity_cli, Prerequisites.Failed _)
           | (Prerequisites.Muse_cli, Prerequisites.Failed _)
           | (Prerequisites.Pdf_tools, Prerequisites.Failed _)
           | (Prerequisites.Whisper_cli, Prerequisites.Failed _)
           | (Prerequisites.Geckodriver, Prerequisites.Failed _)
           | (Prerequisites.Firefox, Prerequisites.Failed _)
           | (Prerequisites.Ego_browser, Prerequisites.Failed _)
           | (Prerequisites.Searxng _, Prerequisites.Failed _) -> receipt, 1
           | (Prerequisites.Sandbox _, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Codex_cli, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Claude_cli, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Antigravity_cli, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Muse_cli, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Pdf_tools, External_step_pending)
           | (Prerequisites.Whisper_cli, (External_step_pending | Commands_completed_recheck_required))
           | (Prerequisites.Geckodriver, External_step_pending)
           | (Prerequisites.Firefox, External_step_pending)
           | (Prerequisites.Ego_browser, External_step_pending)
           | (Prerequisites.Searxng _, External_step_pending) -> receipt, 0 in
         print_endline (Yojson.Safe.to_string receipt);
         code)
