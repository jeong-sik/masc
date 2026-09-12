type distribution = Debian | Ubuntu | Other
type dependency = Sandbox of Sandbox_readiness.backend | Codex_cli | Claude_cli | Antigravity_cli | Pdf_tools | Presentation_tools of {base_path:string}
type action_effect = Open_official_installer of { url : string; argv : string list }
  | Run_commands of string list list
  | Install_official_cli of Runtime_official_cli_install.client
type action = { id : string; label : string; detail : string;
  source_url : string; requires_admin : bool; action_effect : action_effect }
type outcome = External_step_pending | Commands_completed_recheck_required
  | Failed of { step : int; reason : string }

let distribution_of_os_release contents =
  (* /etc/os-release is data, never sourced by a shell. Only its exact ID is
     needed; ID_LIKE does not prove that a derivative ships the same package. *)
  let ids = String.split_on_char '\n' contents |> List.filter_map (fun line ->
    match String.split_on_char '=' (String.trim line) with
    | ["ID"; value] -> Some value | _ -> None) in
  match ids with
  | ["debian"] | ["\"debian\""] | ["'debian'"] -> Debian
  | ["ubuntu"] | ["\"ubuntu\""] | ["'ubuntu'"] -> Ubuntu
  | _ -> Other

let apple_source = "https://github.com/apple/container/releases/latest"
let docker_mac_source = "https://docs.docker.com/desktop/setup/install/mac-install/"
let docker_linux_source = "https://docs.docker.com/engine/install/"
let codex_source = "https://developers.openai.com/codex/cli/"
let claude_source = "https://code.claude.com/docs/en/setup"

let open_action ~host ~id ~label ~detail ~source_url url =
  let argv = match host with
    | Sandbox_readiness.Macos _ -> ["open"; url]
    | Linux _ -> ["xdg-open"; url]
    | Unsupported -> [] in
  {id; label; detail; source_url; requires_admin=false;
   action_effect=Open_official_installer {url; argv}}
let commands ~id ~label ~detail ~source_url ~requires_admin argv =
  {id; label; detail; source_url; requires_admin; action_effect=Run_commands argv}
let install_cli client =
  let name = Runtime_official_cli_install.name client in
  {id=name ^ "_native_install"; label="Install " ^ name ^ " using its official installer";
   detail="Download and run the vendor's native installer for this account. It may manage its own client files and shell integration. No sudo or Homebrew is requested. Sign-in and model verification follow separately.";
   source_url=Runtime_official_cli_install.source_url client; requires_admin=false;
   action_effect=Install_official_cli client}
let catalog ~host ~distribution dependency =
  let open_ = open_action ~host in
  match dependency, host with
  | _, Sandbox_readiness.Unsupported -> []
  | Codex_cli, _ -> [install_cli Codex; open_ ~id:"codex_official_install" ~label:"Open official Codex installation"
      ~detail:"Follow the official client installation. Return here to detect the client, sign in, and verify your selected model."
      ~source_url:codex_source codex_source]
  | Claude_cli, _ -> [install_cli Claude; open_ ~id:"claude_official_install" ~label:"Open official Claude Code installation"
      ~detail:"Follow the official client installation. Return here to detect the client, sign in, and verify your selected model."
      ~source_url:claude_source claude_source]
  | Antigravity_cli, _ -> [install_cli Antigravity;
      open_ ~id:"agy_official_install" ~label:"Open official Antigravity installation"
        ~detail:"Follow the vendor instructions, then return to sign in and verify the selected model."
        ~source_url:(Runtime_official_cli_install.source_url Antigravity)
        (Runtime_official_cli_install.source_url Antigravity)]
  | Presentation_tools {base_path}, (Macos _ | Linux _) ->
    let parser = commands ~id:"presentation_parser_install" ~label:"Install the presentation parser for this workspace"
      ~detail:"Create a Python virtual environment under this workspace's .masc/runtime-tools/presentation and install python-pptx from PyPI. Uses the current host python3; it must support venv and pip. System Python, immutable release files, and producer containers are not modified."
      ~source_url:"https://python-pptx.readthedocs.io/en/latest/user/install.html" ~requires_admin:false
      (Presentation_runtime_dependencies.parser_install_commands ~base_path) in
    let renderer = match host,distribution with
      | Macos _, _ -> [commands ~id:"presentation_renderer_install" ~label:"Install LibreOffice with Homebrew"
          ~detail:"Use existing Homebrew to install the LibreOffice cask and its soffice command. MASC does not install Homebrew or developer tools. This is a host application install, separate from the workspace parser."
          ~source_url:"https://formulae.brew.sh/cask/libreoffice" ~requires_admin:false
          [["brew";"install";"--cask";"libreoffice"]]]
      | Linux _, (Debian | Ubuntu) -> [commands ~id:"presentation_renderer_install" ~label:"Install LibreOffice Impress from distribution repositories"
          ~detail:"Use sudo to refresh signed distribution package indexes and install LibreOffice Impress and Python venv support. Parser installation remains a separate workspace action."
          ~source_url:"https://www.libreoffice.org/installation-instructions/" ~requires_admin:true
          [["sudo";"apt-get";"update"];["sudo";"apt-get";"install";"-y";"libreoffice-impress";"python3-venv"]]]
      | Linux _, Other -> [open_ ~id:"presentation_renderer_instructions" ~label:"Open LibreOffice installation instructions"
          ~detail:"Install LibreOffice using your distribution's instructions and make soffice available in the service host PATH. Return to refresh detection."
          ~source_url:"https://www.libreoffice.org/installation-instructions/" "https://www.libreoffice.org/installation-instructions/"]
      | Unsupported, _ -> [] in
    renderer @ [parser]
  | Pdf_tools, Macos _ ->
    [commands ~id:"poppler_install" ~label:"Install PDF inspection tools with Homebrew"
       ~detail:"Install Poppler through the existing Homebrew package manager. Homebrew must already be installed; MASC does not install Homebrew or developer tools. Both PDF commands are checked after installation."
       ~source_url:"https://formulae.brew.sh/formula/poppler" ~requires_admin:false
       [["brew";"install";"poppler"]]]
  | Pdf_tools, Linux _ ->
    (match distribution with
     | Debian | Ubuntu ->
       let source_url = match distribution with
         | Debian -> "https://packages.debian.org/stable/poppler-utils"
         | Ubuntu -> "https://packages.ubuntu.com/noble/poppler-utils"
         | Other -> "https://poppler.freedesktop.org/" in
       [commands ~id:"poppler_install" ~label:"Install PDF inspection tools from distribution repositories"
          ~detail:"Use sudo to refresh signed package indexes and install poppler-utils. Both PDF commands are checked after installation."
          ~source_url ~requires_admin:true
          [["sudo";"apt-get";"update"];["sudo";"apt-get";"install";"-y";"poppler-utils"]]]
     | Other -> [])
  | Sandbox Sandbox_readiness.Apple_container, Macos {architecture=Arm64; major} when major >= 26 ->
    [open_ ~id:"apple_container_official_install" ~label:"Open Apple Container signed installer"
       ~detail:"Choose the signed installer package on Apple's release page and complete the macOS installer. Opening this page does not install or verify the package."
       ~source_url:apple_source apple_source;
     commands ~id:"apple_container_start" ~label:"Start Apple Container service"
       ~detail:"Start the installed service for this account, then recheck sandbox prerequisites."
       ~source_url:apple_source ~requires_admin:false [["container";"system";"start"]]]
  | Sandbox Docker, Macos {architecture; _} ->
    let arch = match architecture with Arm64 -> "arm64" | X64 -> "amd64" in
    let url = "https://desktop.docker.com/mac/main/" ^ arch ^ "/Docker.dmg" in
    [open_ ~id:"docker_desktop_official_install" ~label:"Download the official Docker Desktop installer"
       ~detail:"Complete Docker Desktop's macOS installation and any vendor terms. This opens the architecture-specific official download; it does not assert installation or signature verification."
       ~source_url:docker_mac_source url;
     commands ~id:"docker_desktop_start" ~label:"Open installed Docker Desktop"
       ~detail:"Launch Docker Desktop and finish its first-start prompts, then recheck the engine."
       ~source_url:docker_mac_source ~requires_admin:false [["open";"-a";"Docker"]]]
  | Sandbox Docker, Linux _ ->
    let install = match distribution with
      | Debian | Ubuntu ->
        let source_url = match distribution with
          | Debian -> "https://packages.debian.org/stable/docker.io"
          | Ubuntu -> "https://packages.ubuntu.com/noble/docker.io"
          | Other -> docker_linux_source in
        [commands ~id:"docker_distribution_install" ~label:"Install Docker from configured distribution repositories"
           ~detail:"Use sudo to refresh package indexes and install docker.io from your configured signed repositories. Availability depends on the OS release and enabled repositories. Access for your current account is checked afterwards; no group membership is changed."
           ~source_url ~requires_admin:true
           [["sudo";"apt-get";"update"];["sudo";"apt-get";"install";"-y";"docker.io"]]]
      | Other -> [] in
    install @ [
      open_ ~id:"docker_linux_official_instructions" ~label:"Open Docker Engine installation instructions"
        ~detail:"Choose the instructions for your distribution. Return here after installation to check service and current-account access."
        ~source_url:docker_linux_source docker_linux_source;
      commands ~id:"docker_linux_start" ~label:"Start Docker service with systemd"
        ~detail:"Requires sudo and a systemd host. Start the existing service, then recheck it from this account. Non-systemd hosts should use their distribution's instructions."
        ~source_url:docker_linux_source ~requires_admin:true [["sudo";"systemctl";"start";"docker"]]]
  | Sandbox Nerdctl_kata, Linux _ ->
    let url = "https://github.com/kata-containers/kata-containers/tree/main/docs/install" in
    [open_ ~id:"kata_official_install" ~label:"Open Kata and containerd installation instructions"
       ~detail:"Prepare hardware virtualization, containerd, nerdctl and the Kata runtime. This advanced backend is checked before image preparation."
       ~source_url:url url]
  | Sandbox (Apple_container | Nerdctl_kata | Microsandbox | Remote_ssh), _ -> []

let effect_json = function
  | Install_official_cli client -> `Assoc ["kind", `String "official_cli_install";
      "client", `String (Runtime_official_cli_install.name client)]
  | Open_official_installer {url; argv} -> `Assoc ["kind",`String "open_official_installer";
      "url",`String url; "argv",`List (List.map (fun s -> `String s) argv)]
  | Run_commands steps -> `Assoc ["kind",`String "run_commands";
      "argv_steps",`List (List.map (fun argv -> `List (List.map (fun s -> `String s) argv)) steps)]
let to_json actions = `Assoc ["schema",`String "masc.prerequisite_actions.v1";
  "actions",`List (List.map (fun action -> `Assoc [
    "id",`String action.id; "label",`String action.label; "detail",`String action.detail;
    "source_url",`String action.source_url; "requires_admin",`Bool action.requires_admin;
    "effect",effect_json action.action_effect; "completion",`String "recheck_required"]) actions)]
let execute ~run action =
  let rec commands completed index = function
    | [] -> completed
    | [] :: _ -> Failed {step=index; reason="This host cannot launch the installation page; open its source URL manually"}
    | argv :: rest -> (match run argv with
      | Ok () -> commands completed (index+1) rest
      | Error _ -> Failed {step=index; reason="The selected prerequisite action did not finish. Check its terminal output, correct the prerequisite, and retry or choose another backend."}) in
  match action.action_effect with
  | Install_official_cli client ->
    (match Runtime_official_cli_install.install ~run client with
     | Ok () -> Commands_completed_recheck_required
     | Error reason -> Failed {step=1; reason})
  | Open_official_installer {argv; _} -> commands External_step_pending 1 [argv]
  | Run_commands steps -> commands Commands_completed_recheck_required 1 steps
let outcome_to_json outcome =
  let status, fields = match outcome with
    | External_step_pending -> "external_step_pending", []
    | Commands_completed_recheck_required -> "commands_completed_recheck_required", []
    | Failed {step;reason} -> "failed", ["step",`Int step;"reason",`String reason] in
  `Assoc (["schema",`String "masc.prerequisite_action_result.v1";
           "status",`String status;"readiness",`String "not_checked"] @ fields)
