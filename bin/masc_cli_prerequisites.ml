module Sandbox = Masc.Sandbox_readiness
module Prerequisites = Masc.Sandbox_prerequisites
module Apple = Masc.Apple_container_install
module Docker = Masc.Docker_desktop_install
type action = Standard of Prerequisites.action | Verified_apple_install
  | Verified_docker_install | Verified_docker_launch
let dependency = function
  | "codex" -> Some Prerequisites.Codex_cli
  | "claude-code" -> Some Prerequisites.Claude_cli
  | "antigravity" -> Some Prerequisites.Antigravity_cli
  | "pdf-tools" -> Some Prerequisites.Pdf_tools
  | "whisper" -> Some Prerequisites.Whisper_cli
  | name -> Option.map (fun backend -> Prerequisites.Sandbox backend) (Sandbox.backend_of_id name)

(* Where a downloaded model lands. A cache directory rather than anywhere under
   masc: the file is whisper's, masc only names its path in the configuration,
   and nothing here deletes or refreshes it. Absent HOME, the catalog opens the
   downloads page instead of offering a command with nowhere to write. *)
let model_dir () =
  Option.map
    (fun home -> Filename.concat (Filename.concat home ".cache") "whisper")
    (Sys.getenv_opt "HOME")
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
  | Ok _ | Error _ -> Error ()
let id = function Standard action -> action.Prerequisites.id
  | Verified_apple_install -> "apple_container_verified_install"
  | Verified_docker_install -> "docker_desktop_verified_install"
  | Verified_docker_launch -> "docker_desktop_verified_launch"
let actions host dependency =
  let distribution = try
    In_channel.with_open_text "/etc/os-release" In_channel.input_all
    |> Prerequisites.distribution_of_os_release
    with Sys_error _ -> Prerequisites.Other in
  let standard =
    Prerequisites.catalog ?model_dir:(model_dir ()) ~host ~distribution dependency
    |> List.map (fun action -> Standard action)
  in
  match host, dependency with
  | Sandbox.Macos {architecture=Arm64; major}, Prerequisites.Sandbox Apple_container when major >= 26 ->
    Verified_apple_install :: standard
  | Sandbox.Macos _, Prerequisites.Sandbox Docker ->
    Verified_docker_install :: Verified_docker_launch :: standard
  | _ -> standard
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
let run ~dependency:name ~action =
  match dependency name with
  | None -> prerr_endline "Unknown prerequisite. Choose a dependency from the setup catalog."; 1
  | Some dependency ->
    let host = Sandbox.detect_host ~run:Sandbox.system_runner in
    let actions = actions host dependency in
    match action with
    | None ->
      let catalog = to_json actions in
      let catalog = match dependency, catalog with
        | Prerequisites.Pdf_tools, `Assoc fields ->
          `Assoc (("dependency_readiness", Masc.Pdf_runtime_dependencies.(observe () |> to_json)) :: fields)
        | (Sandbox _ | Codex_cli | Claude_cli | Antigravity_cli | Whisper_cli), _ -> catalog
        | Pdf_tools, _ -> invalid_arg "prerequisite catalog encoder must return an object" in
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
           | _, Prerequisites.Failed _ -> receipt, 1
           | _, (External_step_pending | Commands_completed_recheck_required) -> receipt, 0 in
         print_endline (Yojson.Safe.to_string receipt);
         code)
