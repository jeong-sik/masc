type distribution = Debian | Ubuntu | Other
type searxng_container =
  | Searxng_absent
  | Searxng_stopped
  | Searxng_running
  | Searxng_paused
  | Searxng_restarting
  | Searxng_unusable of string
type dependency = Sandbox of Sandbox_readiness.backend | Codex_cli | Claude_cli | Antigravity_cli
  | Muse_cli | Pdf_tools | Presentation_tools of {base_path:string} | Whisper_cli
  | Geckodriver | Firefox | Ego_browser | Searxng of { config_dir : string }
type action_effect = Open_official_installer of { url : string; argv : string list }
  | Run_commands of string list list
  | Install_official_cli of Runtime_official_cli_install.client
  | Build_without_rosetta of { user_config : string }
  | Run_searxng of { config_dir : string }
  | Start_existing_searxng
type apple_builder = Builder_unchecked | Needs_missing_rosetta of { user_config : string option }
                   | Needs_default_kernel
type action = { id : string; label : string; detail : string;
  source_url : string; requires_admin : bool; action_effect : action_effect;
  writes : string option }
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
let apple_build_config_source = "https://github.com/apple/container/blob/main/docs/container-system-config.md"
let rosetta_source = "https://support.apple.com/en-us/102527"
(* The service reads the user file once, when it starts, and copies it; a
   changed file is not what the next build uses until the service restarts
   (apple/container SystemStart, 1.3.1 and 1.4.1). *)
let container_restart = [["container";"system";"stop"];["container";"system";"start"]]
let docker_mac_source = "https://docs.docker.com/desktop/setup/install/mac-install/"
let docker_linux_source = "https://docs.docker.com/engine/install/"
let codex_source = "https://developers.openai.com/codex/cli/"
let claude_source = "https://code.claude.com/docs/en/setup"
(* The program every Homebrew step runs, and where Homebrew itself comes from.
   One name so that a step that could not find it can be told apart by the
   value this catalog put in argv, not by reading anything a child printed. *)
let homebrew = "brew"
let homebrew_source = "https://brew.sh"
let whisper_source = "https://github.com/ggml-org/whisper.cpp"
let whisper_formula_source = "https://formulae.brew.sh/formula/whisper-cpp"
let whisper_models_source = "https://huggingface.co/ggerganov/whisper.cpp"
let sox_formula_source = "https://formulae.brew.sh/formula/sox"
let sox_source = "https://sourceforge.net/projects/sox/"
let geckodriver_formula_source = "https://formulae.brew.sh/formula/geckodriver"
let geckodriver_source = "https://github.com/mozilla/geckodriver/releases"
let searxng_docker_source = "https://docs.searxng.org/admin/installation-docker.html"
let firefox_cask_source = "https://formulae.brew.sh/cask/firefox"
let firefox_linux_source = "https://support.mozilla.org/en-US/kb/install-firefox-linux"
let ego_lite_source = "https://lite.ego.app/"

(* The model masc asks whisper for by default. Measured 2026-09-12: this file
   is 1,624,555,275 bytes, and on an M3 Max it transcribed a Korean sentence in
   5.1s with the language auto-detected at p = 0.998641. The smaller models
   download faster and hear Korean worse. *)
let whisper_model_file = "ggml-large-v3-turbo.bin"

let whisper_model_url =
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" ^ whisper_model_file

(* The container SearXNG runs in. One name, so a second run finds the first
   rather than starting another; [scripts/searxng-local.sh] names its container
   the same, so a stopped container that script made is the one a start
   action would run, with the publish address and mount that script gave it.
   The image is a dated tag and the digest the tag resolved to on 2026-10-14
   (the digest [latest] had that day too, answering 22 queries): a tag can be
   re-pointed and [latest] is a different program each day this is run, so
   the digest is what is fixed. GHCR rather than Docker Hub, whose anonymous
   pulls are rate limited (docs.searxng.org, Docker installation). *)
let searxng_container_name = "masc-searxng"
let searxng_image =
  "ghcr.io/searxng/searxng:2026.10.13-22c64b8d3@sha256:9b61996edcc679fb6665290f95fda15389a14eda6060e41a25c63ab2758f2436"
let searxng_container_port = 8080
let searxng_settings_file = "settings.yml"
let searxng_settings_path config_dir = Filename.concat config_dir searxng_settings_file

(* What the container reads from [/etc/searxng]. JSON is on because masc's
   search tool asks for it; the limiter is off because the only client is this
   host; the secret key is generated for this install. There is deliberately
   no [server.bind_address] or [server.port]: the image execs granian, which
   takes its bind and port from [GRANIAN_HOST]/[GRANIAN_PORT] ([::]:8080 in
   the image), and those two settings only apply to a direct
   [python searx/webapp.py] run (docs.searxng.org settings/server). Measured
   2026-10-17: the pinned image booted and answered /search on 8080 with
   neither line present. [scripts/searxng-local.sh] writes the same text; a
   test pins the two spellings equal. *)
let searxng_settings ~secret_key =
  String.concat "\n"
    [ "use_default_settings: true"
    ; ""
    ; "search:"
    ; "  formats:"
    ; "    - html"
    ; "    - json"
    ; ""
    ; "server:"
    ; "  limiter: false"
    ; Printf.sprintf "  secret_key: \"%s\"" secret_key
    ; "" ]

let searxng_published_port = Masc_network_defaults.searxng_default_port

let searxng_pull = ["docker"; "pull"; searxng_image]
(* [--cap-drop ALL --security-opt no-new-privileges]: the entrypoint chowns
   its mounts (failures on this read-only one are ignored noise) and execs
   granian as the same uid, so no capability or privilege transition is
   needed. Measured 2026-10-17 on the pinned image: boots, /healthz 200,
   /search answers 20 results, with both flags. *)
let searxng_run ~config_dir =
  ["docker"; "run"; "--detach"; "--name"; searxng_container_name;
   "--restart"; "unless-stopped";
   "--cap-drop"; "ALL";
   "--security-opt"; "no-new-privileges:true";
   "--publish"; Printf.sprintf "%s:%d:%d" Masc_network_defaults.searxng_published_host
                  searxng_published_port searxng_container_port;
   "--volume"; config_dir ^ ":/etc/searxng:ro"; searxng_image]
let searxng_start = ["docker"; "start"; searxng_container_name]

(* A stopped container keeps the publish address, mount and image it was
   created with, so it is started and nothing about it is decided here. A
   paused one is refused by [docker start], a restarting one is already
   running as far as Docker says, and an unusable one cannot be started: they
   have no effect, so none can be named. *)
let searxng_run_steps ~config_dir = [searxng_pull; searxng_run ~config_dir]
let searxng_start_steps = [searxng_start]

let open_action ~host ~id ~label ~detail ~source_url url =
  let argv = match host with
    | Sandbox_readiness.Macos _ -> ["open"; url]
    | Linux _ -> ["xdg-open"; url]
    | Unsupported -> [] in
  {id; label; detail; source_url; requires_admin=false;
   action_effect=Open_official_installer {url; argv}; writes=None}
let commands ?writes ~id ~label ~detail ~source_url ~requires_admin argv =
  {id; label; detail; source_url; requires_admin; action_effect=Run_commands argv; writes}
let install_cli client =
  let name = Runtime_official_cli_install.name client in
  {id=name ^ "_native_install"; label="Install " ^ name ^ " using its official installer";
   detail="Download and run the vendor's native installer for this account. It may manage its own client files and shell integration. No sudo or Homebrew is requested. Sign-in and model verification follow separately.";
   source_url=Runtime_official_cli_install.source_url client; requires_admin=false;
   action_effect=Install_official_cli client; writes=None}
let rosetta_choices ~user_config =
  let without = match user_config with
    | None -> []
    | Some user_config ->
      [{id="apple_container_build_without_rosetta"; label="Build images without Rosetta";
        detail="Writes rosetta = false under [build] in " ^ user_config ^ ", then restarts the Apple Container service. Containers running in Apple Container stop during the restart. Builds then make arm64 images only, which is what MASC's sandbox image is; remove the line to build amd64 images again.";
        source_url=apple_build_config_source; requires_admin=false;
        action_effect=Build_without_rosetta {user_config}; writes=Some user_config}] in
  without @ [commands ~id:"rosetta_install" ~label:"Install Rosetta"
    ~detail:"Runs Apple's Rosetta installer, which shows Apple's license and may ask for your password. Rosetta also lets this Mac run Intel apps and build amd64 images."
    ~source_url:rosetta_source ~requires_admin:true [["softwareupdate";"--install-rosetta"]]]
let rec catalog ?model_dir ?(apple_builder=Builder_unchecked)
    ?(searxng_container=Searxng_absent) ~host ~distribution dependency =
  let open_ = open_action ~host in
  (* whisper-cli needs a model as well as a binary, on either host, and -m is
     a path the voice configuration then names. Written once because the hosts
     differ only in how the binary arrives: the Linux branch named the binary
     and stopped, so an operator who followed that plan to its end still had
     nothing to transcribe with. *)
  let whisper_model_step () =
    match model_dir with
    (* Without somewhere to put it there is no command to offer, so the page
       is opened instead of a download being faked. *)
    | None ->
      open_ ~id:"whisper_model_page"
        ~label:"Open the whisper.cpp model downloads"
        ~detail:"Choose a ggml model and note where it lands: the voice configuration names that path."
        ~source_url:whisper_models_source whisper_models_source
    | Some dir ->
      let final = Filename.concat dir whisper_model_file in
      (* [writes] is the final path, stated as data. A reader that needs to
         know where the model landed used to take the curl [-o] argument, and
         when the fetch moved to a [.part] beside the path that argument became
         a file that never exists after a successful download. *)
      commands ~writes:final ~id:"whisper_model_download"
        ~label:"Download the whisper model masc asks for"
        ~detail:"Fetches ggml-large-v3-turbo (1.6GB), which auto-detects Korean. The voice configuration names this path as the section's model."
        ~source_url:whisper_models_source ~requires_admin:false
        [ (* -f, or an HTTP error body is written under the model's name and
             curl still exits 0: the plan then reports the prerequisite done
             and leaves 1.6GB of error page where whisper expects a model.
             Fetched beside the final path and moved only after curl
             succeeded, so a run that dies part way leaves nothing at the path
             the configuration points at. *)
          [ "curl"; "-fL"; "--create-dirs"; "-o"; final ^ ".part"; whisper_model_url ]
        ; [ "mv"; final ^ ".part"; final ]
        ]
  in
  match dependency, host with
  | _, Sandbox_readiness.Unsupported -> []
  (* Hearing is the only half of voice a fresh mac cannot already do: say is in
     the base system, and nothing transcribes. Both steps here are one-shot --
     a package and a file -- because the endpoint that uses them runs a command
     rather than a server. *)
  | Whisper_cli, Macos _ ->
    let install =
      commands ~id:"whisper_cli_brew_install"
        ~label:"Install whisper.cpp with Homebrew"
        ~detail:"Installs the whisper-cpp formula, an 8.9MB bottle whose whisper-cli transcribes an audio file. Requires Homebrew; nothing is started and no service is registered."
        ~source_url:whisper_formula_source ~requires_admin:false
        [[homebrew;"install";"whisper-cpp"]]
    in
    (* Transcribing is not the whole of hearing: masc's own capture records
       with sox's [rec] and marks the start and end of a recording with sox's
       [play]. Neither is in the base system, and neither failure says so --
       the tones are swallowed at debug level and the recorder surfaces its
       own process error. A device that posts audio to
       [POST /api/v1/voice/transcribe] needs none of this; a person speaking
       into masc does. *)
    let recorder =
      commands ~id:"sox_brew_install"
        ~label:"Install sox, which masc records with"
        ~detail:"Installs the sox formula (2.4MB on this machine, version 14.4.2). It provides rec, which masc records a capture with, and play, which sounds the start and end tones. Without it masc can transcribe a file but cannot make one."
        ~source_url:sox_formula_source ~requires_admin:false
        [[homebrew;"install";"sox"]]
    in
    [ install; whisper_model_step (); recorder ]
  (* Homebrew is the only route this catalog can name a command for. Elsewhere
     the build is the project's own, and guessing a package would install
     something that may not exist. *)
  (* sox is packaged here, unlike whisper.cpp, so the recorder is a command
     rather than a link even where the transcriber is not. Written per
     distribution because naming one package manager for every Linux installs
     something else or nothing. *)
  | (Whisper_cli, Linux (Sandbox_readiness.Arm64)) | (Whisper_cli, Linux (Sandbox_readiness.X64)) ->
    let recorder =
      match distribution with
      | Debian | Ubuntu ->
        commands ~id:"sox_apt_install"
          ~label:"Install sox, which masc records with"
          ~detail:"Installs the sox package. It provides rec, which masc records a capture with, and play, which sounds the start and end tones. Without it masc can transcribe a file but cannot make one."
          ~source_url:sox_source ~requires_admin:true
          [["apt-get";"install";"-y";"sox"]]
      | Other ->
        open_ ~id:"sox_project_page"
          ~label:"Open the sox project page"
          ~detail:"masc records a capture with sox's rec and sounds its tones with sox's play. Install it the way this distribution packages it."
          ~source_url:sox_source sox_source
    in
    [ open_ ~id:"whisper_cli_build_instructions"
        ~label:"Open whisper.cpp build instructions"
        ~detail:"Build whisper.cpp for this machine, then point the voice configuration at the binary and a ggml model."
        ~source_url:whisper_source whisper_source
    ; whisper_model_step ()
    ; recorder
    ]
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
  | Muse_cli, _ -> [install_cli Muse;
      open_ ~id:"muse_official_install" ~label:"Open official Muse Code installation"
        ~detail:"Follow the vendor instructions. Muse Code asks for its own sign-in the first time it runs."
        ~source_url:(Runtime_official_cli_install.source_url Muse)
        (Runtime_official_cli_install.source_url Muse)]
  | (Presentation_tools { base_path }, (Macos _ | Linux (Sandbox_readiness.Arm64)))
  | (Presentation_tools { base_path }, Linux (Sandbox_readiness.X64)) ->
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
    renderer @ [parser] @ catalog ?model_dir ~host ~distribution Pdf_tools
  (* The automation lane starts geckodriver itself, and geckodriver starts
     Firefox, so a workspace needs both on the host. One action each: neither
     is a service, and neither action writes runtime.toml -- naming the
     executable there is a separate step, which needs the absolute path this
     install leaves behind and so has to follow it. *)
  | Geckodriver, Macos _ ->
    [commands ~id:"geckodriver_brew_install" ~label:"Install geckodriver with Homebrew"
       ~detail:"Install the geckodriver formula through the existing Homebrew package manager. Homebrew must already be installed; MASC does not install Homebrew or developer tools. The executable is checked after installation. Naming it in runtime.toml and restarting the server are separate steps."
       ~source_url:geckodriver_formula_source ~requires_admin:false
       [[homebrew;"install";"geckodriver"]]]
  | Geckodriver, Linux _ ->
    [open_ ~id:"geckodriver_releases" ~label:"Open the geckodriver releases"
       ~detail:"Download the release for this machine and put its geckodriver executable on the PATH of the shell that runs this check, then refresh detection. Detection reports the absolute path it found; that path is what runtime.toml names. Distributions package it under different names, so this opens the project's own releases instead of guessing one."
       ~source_url:geckodriver_source geckodriver_source]
  | Firefox, Macos _ ->
    [commands ~id:"firefox_brew_install" ~label:"Install Firefox with Homebrew"
       ~detail:"Install the Firefox cask through the existing Homebrew package manager. Homebrew must already be installed; MASC does not install Homebrew or developer tools. Homebrew stops without changing anything when Firefox.app is already in /Applications; that Firefox is used as it is. The executable is checked after installation."
       ~source_url:firefox_cask_source ~requires_admin:false
       [[homebrew;"install";"--cask";"firefox"]]]
  | Firefox, Linux _ ->
    [open_ ~id:"firefox_install_instructions" ~label:"Open Firefox installation instructions"
       ~detail:"Install Firefox the way this distribution packages it, then refresh detection."
       ~source_url:firefox_linux_source firefox_linux_source]
  (* ego lite installs as a macOS app, and its onboarding puts ego-browser on
     PATH; there is no package to run. It has no Linux build. *)
  | Ego_browser, Macos _ ->
    [open_ ~id:"ego_lite_download" ~label:"Open the ego lite download page"
       ~detail:"Install ego lite and finish its first-run onboarding in the app, which links ego-browser into ~/.local/bin, then refresh detection."
       ~source_url:ego_lite_source ego_lite_source]
  | Ego_browser, Linux _ -> []
 (* SearXNG is the one search provider that needs no key. Both hosts run it
     the same way, in a container the operator's Docker already provides; a
     host without Docker gets the start action and a failure that names the
     missing program, not a guess at how to install Docker. A container that
     is already running has nothing left to start. *)
  | Searxng {config_dir}, (Macos _ | Linux _) ->
    (match searxng_container with
     | Searxng_running | Searxng_paused | Searxng_restarting | Searxng_unusable _ -> []
     | Searxng_stopped ->
       [{id = "searxng_docker_start_existing"; label = "Start the SearXNG container";
         detail = Printf.sprintf "Starts the existing %s container as Docker created it: the address it is published on, the directory it mounts and the image it runs are the ones it already has, and nothing is written. Docker must be running." searxng_container_name;
         source_url = searxng_docker_source; requires_admin = false;
         action_effect = Start_existing_searxng;
         writes = None}]
     | Searxng_absent ->
       [{id = "searxng_docker_run"; label = "Run SearXNG in a Docker container";
         detail = Printf.sprintf "Writes %s if it is not there (JSON output on, a generated secret key, no request limiter), then pulls %s and starts a container named %s that Docker restarts whenever it starts, until it is stopped (--restart unless-stopped). The port is published on %s:%d only, and the settings directory is mounted read-only. The image also declares a cache volume, which Docker creates anonymously. Docker must be running."
                    (searxng_settings_path config_dir) searxng_image searxng_container_name
                    Masc_network_defaults.searxng_published_host searxng_published_port;
         source_url = searxng_docker_source; requires_admin = false;
         action_effect = Run_searxng {config_dir};
         writes = Some (searxng_settings_path config_dir)}])
  | Pdf_tools, Macos _ ->
    [commands ~id:"poppler_install" ~label:"Install PDF inspection tools with Homebrew"
       ~detail:"Install Poppler through the existing Homebrew package manager. Homebrew must already be installed; MASC does not install Homebrew or developer tools. Both PDF commands are checked after installation."
       ~source_url:"https://formulae.brew.sh/formula/poppler" ~requires_admin:false
       [[homebrew;"install";"poppler"]]]
  | (Pdf_tools, Linux (Sandbox_readiness.Arm64)) | (Pdf_tools, Linux (Sandbox_readiness.X64)) ->
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
    (match apple_builder with
     (* A service that answered and a builder that cannot start is one missing
        piece, not a missing install: offering the installer again here would
        send the operator away from the choice that unblocks the build. *)
     | Needs_missing_rosetta {user_config} -> rosetta_choices ~user_config
     | Needs_default_kernel ->
       [commands ~id:"apple_container_kernel_set" ~label:"Install the recommended default kernel"
          ~detail:"Downloads Apple's recommended kernel for this architecture and sets it as Apple Container's default; every image build boots it. Needs the service running and network access, and downloads a few hundred megabytes."
          ~source_url:apple_source ~requires_admin:false
          [["container";"system";"kernel";"set";"--recommended"]]]
     | Builder_unchecked ->
       [open_ ~id:"apple_container_official_install" ~label:"Open Apple Container signed installer"
          ~detail:"Choose the signed installer package on Apple's release page and complete the macOS installer. Opening this page does not install or verify the package."
          ~source_url:apple_source apple_source;
        commands ~id:"apple_container_start" ~label:"Start Apple Container service"
          ~detail:"Start the installed service for this account, then recheck sandbox prerequisites."
          ~source_url:apple_source ~requires_admin:false [["container";"system";"start"]]])
  | Sandbox Docker, Macos {architecture; _} ->
    let arch = match architecture with Arm64 -> "arm64" | X64 -> "amd64" in
    let url = "https://desktop.docker.com/mac/main/" ^ arch ^ "/Docker.dmg" in
    [open_ ~id:"docker_desktop_official_install" ~label:"Download the official Docker Desktop installer"
       ~detail:"Complete Docker Desktop's macOS installation and any vendor terms. This opens the architecture-specific official download; it does not assert installation or signature verification."
       ~source_url:docker_mac_source url;
     commands ~id:"docker_desktop_start" ~label:"Open installed Docker Desktop"
       ~detail:"Launch Docker Desktop and finish its first-start prompts, then recheck the engine."
       ~source_url:docker_mac_source ~requires_admin:false [["open";"-a";"Docker"]]]
  | (Sandbox (Docker), Linux (Sandbox_readiness.Arm64))
  | (Sandbox (Docker), Linux (Sandbox_readiness.X64)) ->
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
  | Build_without_rosetta {user_config} -> `Assoc ["kind",`String "build_without_rosetta";
      "user_config",`String user_config;
      "argv_steps",`List (List.map (fun argv -> `List (List.map (fun s -> `String s) argv)) container_restart)]
  (* The secret key is generated when the action runs and is not part of what
     the catalog prints; the file it lands in is [writes]. *)
  | Run_searxng {config_dir} -> `Assoc ["kind",`String "run_searxng";
      "settings_file",`String (searxng_settings_path config_dir);
      "argv_steps",`List (List.map (fun argv -> `List (List.map (fun s -> `String s) argv))
                            (searxng_run_steps ~config_dir))]
  | Start_existing_searxng -> `Assoc ["kind",`String "start_existing_searxng";
      "argv_steps",`List (List.map (fun argv -> `List (List.map (fun s -> `String s) argv))
                            searxng_start_steps)]
let to_json actions = `Assoc ["schema",`String "masc.prerequisite_actions.v1";
  "actions",`List (List.map (fun action -> `Assoc [
    "id",`String action.id; "label",`String action.label; "detail",`String action.detail;
    "source_url",`String action.source_url; "requires_admin",`Bool action.requires_admin;
    "effect",effect_json action.action_effect; "completion",`String "recheck_required";
    "writes",(match action.writes with Some path -> `String path | None -> `Null)]) actions)]
(* Why a step did not complete, as far as the terminal edge can tell without
   repeating anything the child printed. The reason in a receipt is built from
   these and from argv, which this catalog wrote; child diagnostics stay on the
   terminal and have no field here to reach a receipt through. *)
type run_failure =
  | Program_not_found
  | Could_not_start
  | Did_not_finish

let not_found_reason program =
  (* A fresh mac has no Homebrew, and two of the hearing steps are Homebrew
     steps. Measured 2026-09-13 with brew absent from PATH: the receipt said
     "did not finish. Check its terminal output", and there was no output --
     brew never ran. *)
  if String.equal program homebrew then
    Printf.sprintf
      "Homebrew is not installed (%s is not on PATH), so nothing ran. Install it from %s, then retry."
      homebrew homebrew_source
  else Printf.sprintf "%s is not on PATH, so nothing ran. Install it, then retry." program

(* Set [build] rosetta = false and leave every other line as it was. A file
   that is not TOML is refused rather than edited: Apple Container would refuse
   it as well, and a line edit cannot say what the operator meant. The edit
   lands on a symlink's target so a dotfile manager's link keeps pointing at
   the file it manages. *)
(* Links followed before the write, including one whose target does not exist
   yet: Unix.realpath refuses that link, and falling back to the link's own
   path would rename a regular file over it. *)
let max_config_links = 8
let rec config_write_target path followed =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_LNK when followed < max_config_links ->
    let link = Unix.readlink path in
    let next = if Filename.is_relative link then Filename.concat (Filename.dirname path) link else link in
    config_write_target next (followed + 1)
  | Unix.S_LNK | Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> path
(* A file the operator created keeps its permissions; the atomic write would
   otherwise leave the temporary file's 0600 in its place. *)
let new_config_permissions = 0o644
let write_build_without_rosetta user_config =
  let target = config_write_target user_config 0 in
  let permissions = match Unix.stat target with
    | stats -> stats.Unix.st_perm
    | exception Unix.Unix_error (_, _, _) -> new_config_permissions in
  let original = if Sys.file_exists target then
      (match In_channel.with_open_text target In_channel.input_all with
       | contents -> Ok contents
       | exception Sys_error reason -> Error ("Could not read " ^ target ^ ": " ^ reason))
    else Ok "" in
  match original with
  | Error reason -> Error reason
  | Ok original ->
    match Otoml.Parser.from_string_result original with
    | Error _ -> Error (target ^ " is not valid TOML, and Apple Container would refuse it too. Fix it, then retry.")
    | Ok _ ->
      let edited = Toml_line_editor.edit_table_bool original ~path:"build" ~key:"rosetta" ~value:false in
      let recorded = match Otoml.Parser.from_string_result edited with
        | Ok document -> Otoml.find_result document (fun value -> Otoml.get_boolean value) ["build"; "rosetta"]
        | Error reason -> Error reason in
      (match recorded with
       | Ok false ->
         (match Fs_compat.mkdir_p (Filename.dirname target) with
          | () ->
            (match Fs_compat.save_file_atomic_strict target edited with
             | Error reason -> Error ("Could not write " ^ target ^ ": " ^ reason)
             | Ok () ->
               (match Unix.chmod target permissions with
                | () -> Ok ()
                | exception Unix.Unix_error (error, _, _) ->
                  Error ("Wrote " ^ target ^ " but could not restore its permissions: " ^ Unix.error_message error)))
          (* [mkdir_p] goes through Eio when a filesystem is installed and
             through Unix otherwise, so either family can come back. *)
          | exception ((Unix.Unix_error _ | Eio.Io _ | Sys_error _) as failure) ->
            Error ("Could not create " ^ Filename.dirname target ^ ": " ^ Printexc.to_string failure))
       | Ok true | Error _ ->
         Error ("The edit did not leave [build] rosetta = false in " ^ target ^ "; nothing was written."))

(* The settings file is the operator's once it exists: a regular file that is
   there is kept, so a hand edit (an engine turned off, a port changed)
   survives the next run, and the generated secret key is not replaced under a
   running container. Anything else at that path (a directory, or a link that
   leads nowhere) is refused: kept, the container would exit on it, and
   replaced, an operator's link would be overwritten. The file is created by
   [Filename.open_temp_file], which gives it 0o600, so the key is readable by
   this account only from the moment it lands. In the pinned image
   ([searxng_image]), [Config.User] is empty and [/usr/local/searxng/entrypoint.sh]
   execs [granian] directly as uid 0 without dropping privileges (or in
   rootless Docker, uid 0 maps to this host account), so 0o600 on the
   read-only bind mount remains readable by the container process on Linux as
   well as macOS. A file made between the look and the rename is replaced;
   the look is not a lock. *)
let searxng_secret_bytes = 32
let write_searxng_settings config_dir =
  let path = searxng_settings_path config_dir in
  let write () =
    match Fs_compat.mkdir_p config_dir with
    | exception Unix.Unix_error (error, _, _) ->
      Error ("Could not create " ^ config_dir ^ ": " ^ Unix.error_message error)
    | () ->
      let contents = searxng_settings ~secret_key:(Random_id.hex ~bytes:searxng_secret_bytes) in
      (match Fs_compat.save_file_atomic_strict path contents with
       | Error reason -> Error ("Could not write " ^ path ^ ": " ^ reason)
       | Ok () -> Ok ()) in
  match Unix.stat path with
  | {Unix.st_kind = Unix.S_REG; _} -> Ok ()
  | {Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _} ->
    Error (path ^ " is not a regular file. Remove it or move it, then run the action again.")
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (* Absent, or a link whose target is. [lstat] tells the two apart. *)
    (match Unix.lstat path with
     | {Unix.st_kind = Unix.S_LNK; _} ->
       Error (path ^ " is a link that leads nowhere. Remove it or point it at a file, then run the action again.")
     | {Unix.st_kind = (Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _} ->
       Error (path ^ " could not be read. Check its permissions, then run the action again.")
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> write ()
     | exception Unix.Unix_error (error, _, _) ->
       Error ("Could not look at " ^ path ^ ": " ^ Unix.error_message error))
  | exception Unix.Unix_error (error, _, _) ->
    Error ("Could not look at " ^ path ^ ": " ^ Unix.error_message error)

let execute ~run action =
  let rec commands completed index = function
    | [] -> completed
    | [] :: _ -> Failed {step=index; reason="This host cannot launch the installation page; open its source URL manually"}
    | (program :: _ as argv) :: rest -> (match run argv with
      | Ok () -> commands completed (index+1) rest
      | Error Program_not_found -> Failed {step=index; reason=not_found_reason program}
      | Error Could_not_start ->
        Failed {step=index; reason=Printf.sprintf "%s could not be started, so nothing ran." program}
      | Error Did_not_finish -> Failed {step=index; reason="The selected prerequisite action did not finish. Check its terminal output, correct the prerequisite, and retry or choose another backend."}) in
  match action.action_effect with
  | Install_official_cli client ->
    (* The vendor installer takes a text-carrying runner and already keeps
       that text out of its reason (the official-client tests pin it), so the
       failure kind is not needed there and no text is invented for it. *)
    let run argv = Result.map_error (fun (_ : run_failure) -> "") (run argv) in
    (match Runtime_official_cli_install.install ~run client with
     | Ok () -> Commands_completed_recheck_required
     | Error reason -> Failed {step=1; reason})
  | Open_official_installer {argv; _} -> commands External_step_pending 1 [argv]
  | Run_commands steps -> commands Commands_completed_recheck_required 1 steps
  | Build_without_rosetta {user_config} ->
    (match write_build_without_rosetta user_config with
     | Error reason -> Failed {step=1; reason}
     | Ok () -> commands Commands_completed_recheck_required 2 container_restart)
  | Run_searxng {config_dir} ->
    (match write_searxng_settings config_dir with
     | Error reason -> Failed {step=1; reason}
     | Ok () -> commands Commands_completed_recheck_required 2 (searxng_run_steps ~config_dir))
  | Start_existing_searxng ->
    (* No settings are written for a mount the container may not have, so its
       one step is numbered from 1. *)
    commands Commands_completed_recheck_required 1 searxng_start_steps
let outcome_to_json outcome =
  let status, fields = match outcome with
    | External_step_pending -> "external_step_pending", []
    | Commands_completed_recheck_required -> "commands_completed_recheck_required", []
    | Failed {step;reason} -> "failed", ["step",`Int step;"reason",`String reason] in
  `Assoc (["schema",`String "masc.prerequisite_action_result.v1";
           "status",`String status;"readiness",`String "not_checked"] @ fields)
