open Alcotest
module P = Masc.Sandbox_prerequisites
module S = Masc.Sandbox_readiness
let mac architecture major = S.Macos {architecture;major}
let actions host distribution backend = P.catalog ~host ~distribution (P.Sandbox backend)
let find id actions = match List.find_opt (fun (action : P.action) -> action.id=id) actions with
  | Some action -> action | None -> fail ("missing action " ^ id)
let test_distribution_boundary () =
  check bool "Ubuntu exact ID" true (P.distribution_of_os_release "NAME=Ubuntu\nID=ubuntu\n" = P.Ubuntu);
  check bool "Debian quoted ID" true (P.distribution_of_os_release "ID=\"debian\"\n" = P.Debian);
  List.iter (fun contents -> check bool "unknown shell or derivative is not assumed compatible" true
    (P.distribution_of_os_release contents=P.Other))
    ["ID_LIKE=ubuntu\n"; "ID=$(touch /tmp/should-not-exist)\n"; "ID=ubuntu\nID=debian\n"; "ID=derivative\nID_LIKE=debian\n"]
let test_platform_choices () =
  check int "Apple not offered on Intel" 0 (List.length (actions (mac S.X64 26) P.Other S.Apple_container));
  check int "Apple not offered on older macOS" 0 (List.length (actions (mac S.Arm64 25) P.Other S.Apple_container));
  check int "Apple not offered on Linux" 0 (List.length (actions (S.Linux S.Arm64) P.Ubuntu S.Apple_container));
  List.iter (fun host ->
    check int "unimplemented msb gets no fake install completion path" 0
      (List.length (actions host P.Other S.Microsandbox))) [mac S.Arm64 26; S.Linux S.X64];
  List.iter (fun (architecture,suffix) ->
    let action = find "docker_desktop_official_install" (actions (mac architecture 26) P.Other S.Docker) in
    match action.action_effect with
    | P.Open_official_installer {url;argv} ->
      check string "official architecture URL" ("https://desktop.docker.com/mac/main/" ^ suffix ^ "/Docker.dmg") url;
      check (list string) "URL passed as one argv item" ["open";url] argv
    | _ -> fail "desktop download must open vendor installer") [S.Arm64,"arm64"; S.X64,"amd64"]
let test_linux_install_is_explicit () =
  let action = find "docker_distribution_install" (actions (S.Linux S.X64) P.Debian S.Docker) in
  check bool "privilege disclosed" true action.requires_admin;
  (match action.action_effect with
   | P.Run_commands steps -> check (list (list string)) "no fetched scripts or group mutation"
       [["sudo";"apt-get";"update"];["sudo";"apt-get";"install";"-y";"docker.io"]] steps
   | _ -> fail "expected distro package manager");
  check bool "unknown distro gets no guessed apt command" false
    (List.exists (fun (a:P.action) -> a.id="docker_distribution_install")
      (actions (S.Linux S.Arm64) P.Other S.Docker));
  let called = ref [] in
  (* The runner reports a kind, not text, so a child's diagnostics have no way
     into the receipt: the reason is built from the kind and the catalog's own
     argv. *)
  let result = P.execute ~run:(fun argv -> called := argv :: !called; Error P.Did_not_finish) action in
  check int "stop at first failure" 1 (List.length !called);
  check bool "failed action retained" true (match result with P.Failed {step=1;_} -> true | _ -> false);
  let serialized = Yojson.Safe.to_string (P.outcome_to_json result) in
  check bool "the reason is the catalog's sentence" true
    (String_util.contains_substring serialized "did not finish")
let test_completion_never_means_ready () =
  let action = find "apple_container_official_install" (actions (mac S.Arm64 26) P.Other S.Apple_container) in
  check bool "opening page remains pending" true
    (P.execute ~run:(fun _ -> Ok ()) action = P.External_step_pending);
  let start = find "apple_container_start" (actions (mac S.Arm64 26) P.Other S.Apple_container) in
  let outcome = P.execute ~run:(fun _ -> Ok ()) start in
  check bool "command success needs recheck" true (outcome=P.Commands_completed_recheck_required);
  check bool "no guest proof claimed" true
    (Yojson.Safe.Util.member "readiness" (P.outcome_to_json outcome)=`String "not_checked")
let test_official_clients_are_explicit_and_not_ready () =
  List.iter (fun (dependency, id) ->
    List.iter (fun host ->
      let action = find id (P.catalog ~host ~distribution:P.Other dependency) in
      check bool "native client installer needs no sudo" false action.requires_admin;
      (match action.action_effect with P.Install_official_cli _ -> () | _ -> fail "missing native installer action");
      let calls = ref [] in
      let outcome = P.execute ~run:(fun argv -> calls := argv :: !calls; Error P.Did_not_finish) action in
      check int "failed download never executes script" 1 (List.length !calls);
      let argv = List.hd !calls in
      check string "only HTTPS downloader starts" "curl" (List.hd argv);
      check bool "redirect protocol bounded to HTTPS" true (List.mem "--proto-redir" argv && List.mem "=https" argv);
      let json = Yojson.Safe.to_string (P.outcome_to_json outcome) in
      check bool "failed action stays failed" true (match outcome with P.Failed _ -> true | _ -> false);
      check bool "no invented reason text" false (String_util.contains_substring json "PRIVATE_FAILURE"))
      [mac S.Arm64 26; S.Linux S.X64])
    [P.Codex_cli,"codex_native_install"; P.Claude_cli,"claude_native_install"; P.Antigravity_cli,"agy_native_install";
     P.Muse_cli,"muse_native_install"]

let test_pdf_tools_reuse_selected_package_managers () =
  List.iter (fun (host, distribution, expected) ->
    let action = find "poppler_install" (P.catalog ~host ~distribution P.Pdf_tools) in
    match action.action_effect with
    | P.Run_commands steps -> check (list (list string)) "explicit PDF package manager" expected steps
    | _ -> fail "PDF tools must use the selected host package manager")
    [mac S.Arm64 26, P.Other, [["brew";"install";"poppler"]];
     S.Linux S.X64, P.Debian, [["sudo";"apt-get";"update"];["sudo";"apt-get";"install";"-y";"poppler-utils"]]];
  check int "unknown Linux distribution gets no guessed apt command" 0
    (List.length (P.catalog ~host:(S.Linux S.X64) ~distribution:P.Other P.Pdf_tools))

let test_presentation_install_is_workspace_owned () =
  let base_path = "/tmp/presentation workspace" in
  let dependency = P.Presentation_tools {base_path} in
  let catalog = P.catalog ~host:(mac S.Arm64 26) ~distribution:P.Other dependency in
  let parser = find "presentation_parser_install" catalog in
  (match parser.action_effect with
   | P.Run_commands steps ->
     check (list (list string)) "parser uses an isolated workspace interpreter"
       [["python3";"-I";"-m";"venv";"--copies";base_path ^ "/.masc/runtime-tools/presentation"];
        [base_path ^ "/.masc/runtime-tools/presentation/bin/python3";"-I";"-m";"pip";"--isolated";"install";"--require-virtualenv";"python-pptx"]] steps
   | _ -> fail "parser must use explicit commands");
  let poppler = find "poppler_install" catalog in
  check bool "PDF tools remain installable from presentation setup" false poppler.requires_admin;
  let renderer = find "presentation_renderer_install" catalog in
  (match renderer.action_effect with
   | P.Run_commands steps -> check (list (list string)) "mac renderer is the official Homebrew cask"
       [["brew";"install";"--cask";"libreoffice"]] steps
   | _ -> fail "renderer install missing");
  let linux = find "presentation_renderer_install"
    (P.catalog ~host:(S.Linux S.X64) ~distribution:P.Debian dependency) in
  check bool "system package privilege is disclosed" true linux.requires_admin;
  check bool "unknown Linux gets no guessed package command" false
    (List.exists (fun (a:P.action) -> a.id="presentation_renderer_install")
      (P.catalog ~host:(S.Linux S.Arm64) ~distribution:P.Other dependency));
  let calls = ref [] in
  let outcome = P.execute ~run:(fun argv -> calls := argv :: !calls; Error P.Did_not_finish) parser in
  check int "venv failure cannot install a package into another Python" 1 (List.length !calls);
  check bool "failed environment creation remains failed" true (match outcome with P.Failed _ -> true | _ -> false)

(* geckodriver and Firefox are the two programs the browser lanes start. On a
   mac they are one Homebrew step each and need no administrator; on Linux the
   package names differ by distribution, so the catalog opens the project's own
   page rather than guess one. *)
let test_browser_tools_use_the_selected_package_manager () =
  List.iter (fun (dependency, id, expected) ->
    let action = find id (P.catalog ~host:(mac S.Arm64 26) ~distribution:P.Other dependency) in
    check bool "Homebrew needs no administrator" false action.requires_admin;
    match action.action_effect with
    | P.Run_commands steps -> check (list (list string)) "explicit Homebrew command" expected steps
    | _ -> fail "a mac install must be a command")
    [P.Geckodriver, "geckodriver_brew_install", [["brew";"install";"geckodriver"]];
     P.Firefox, "firefox_brew_install", [["brew";"install";"--cask";"firefox"]]];
  List.iter (fun distribution ->
    List.iter (fun (dependency, id) ->
      let actions = P.catalog ~host:(S.Linux S.X64) ~distribution dependency in
      check int "one action and no guessed package command" 1 (List.length actions);
      let action = find id actions in
      check bool "opening a page needs no administrator" false action.requires_admin;
      match action.action_effect with
      | P.Open_official_installer {url; argv} ->
        check bool "an https page" true (String.starts_with ~prefix:"https://" url);
        check (list string) "URL passed as one argv item" ["xdg-open"; url] argv
      | _ -> fail "Linux must open the project's page")
      [P.Geckodriver, "geckodriver_releases"; P.Firefox, "firefox_install_instructions"])
    [P.Debian; P.Ubuntu; P.Other];
  List.iter (fun dependency ->
    check int "nothing is offered on an unsupported host" 0
      (List.length (P.catalog ~host:S.Unsupported ~distribution:P.Other dependency)))
    [P.Geckodriver; P.Firefox]

(* ego lite installs as a macOS app whose onboarding puts ego-browser on PATH,
   so a mac gets its download page and nothing to run; it has no Linux build. *)
let test_ego_lite_is_a_download_page_on_a_mac_only () =
  (match P.catalog ~host:(mac S.Arm64 26) ~distribution:P.Other P.Ego_browser with
   | [action] ->
     check string "the download page" "ego_lite_download" action.id;
     check bool "opening a page needs no administrator" false action.requires_admin;
     (match action.action_effect with
      | P.Open_official_installer {url; _} -> check string "ego lite's own site" "https://lite.ego.app/" url
      | _ -> fail "a mac opens ego lite's page")
   | actions -> failf "a mac offers %d actions for ego-browser" (List.length actions));
  List.iter (fun host ->
    check int "nothing elsewhere" 0 (List.length (P.catalog ~host ~distribution:P.Ubuntu P.Ego_browser)))
    [S.Linux S.X64; S.Unsupported]

(* An install action for these never writes runtime.toml: naming the executable
   there needs the path the install leaves behind. *)
let test_browser_tool_actions_write_no_file () =
  List.iter (fun dependency ->
    List.iter (fun host ->
      List.iter (fun (action : P.action) ->
        check (option string) "no file is left behind" None action.writes)
        (P.catalog ~host ~distribution:P.Ubuntu dependency))
      [mac S.Arm64 26; S.Linux S.X64])
    [P.Geckodriver; P.Firefox; P.Ego_browser]

module B = Masc.Browser_runtime_dependencies

(* A scratch directory for fixture programs. Whatever a test leaves in it is
   removed with it. *)
let with_directory f =
  let dir = Filename.temp_file "browser-tools" "" in
  Sys.remove dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () ->
    Array.iter (fun entry ->
      let path = Filename.concat dir entry in
      try Sys.remove path
      with Sys_error _ -> (try Unix.rmdir path with Unix.Unix_error _ -> ()))
      (try Sys.readdir dir with Sys_error _ -> [||]);
    (try Unix.rmdir dir with Unix.Unix_error _ -> ()))
    (fun () -> f dir)

let write_program ?(mode = 0o755) dir name contents =
  let path = Filename.concat dir name in
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  Unix.chmod path mode;
  path

let with_executable ~name contents f =
  with_directory (fun dir -> f dir (write_program dir name contents))

(* The standard library has no unsetenv, so a variable that was unset comes
   back empty. For PATH and HOME that reads the same as unset to everything
   under test. *)
let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:"")) f

let with_cwd dir f =
  let previous = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir previous) f

(* A program that answers its version entry point is what "available" means;
   the path it answered at is what runtime.toml has to name. *)
let test_a_program_that_answers_is_available_at_an_absolute_path () =
  with_executable ~name:"geckodriver" "#!/bin/sh\necho 'geckodriver 9.9.9 (fixture)'\n"
    (fun _ path ->
       match B.probe path with
       | B.Started {path = answered; output; _} as result ->
         check string "the path that answered" path answered;
         check bool "the path is absolute" false (Filename.is_relative answered);
         check bool "the version text is kept" true (String_util.contains_substring output "9.9.9");
         check bool "available" true (B.available result);
         check (option string) "its path" (Some path) (B.path result)
       | B.Missing _ | B.Failed _ -> fail "a program that answers must be Started")

let test_a_program_that_does_not_answer_is_failed_not_missing () =
  with_executable ~name:"geckodriver" "#!/bin/sh\necho broken >&2\nexit 3\n"
    (fun _ path ->
       match B.probe path with
       | B.Failed {status = Unix.WEXITED 3; path = at; _} as result ->
         check string "it exists at this path" path at;
         check bool "not available" false (B.available result)
       | B.Missing _ | B.Started _ | B.Failed _ -> fail "exit 3 must be Failed with its status");
  (match B.probe "/nonexistent-dir/geckodriver" with
   | B.Missing _ as result -> check bool "a missing file is not available" false (B.available result)
   | B.Started _ | B.Failed _ -> fail "an absent file must be Missing")

(* A name is looked up on PATH and answered at the absolute path it was found
   at; an earlier PATH entry wins, as it would when the server starts it. *)
let test_a_name_on_path_resolves_to_an_absolute_path () =
  with_executable ~name:"geckodriver" "#!/bin/sh\necho 'geckodriver 1.2.3'\n"
    (fun dir path ->
       let inherited = Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin" in
       with_env "PATH" (dir ^ ":" ^ inherited) (fun () ->
         match B.observe B.Geckodriver with
         | B.Started {path = answered; _} ->
           check string "the PATH entry's file" path answered;
           check bool "the path is absolute" false (Filename.is_relative answered)
         | B.Missing _ | B.Failed _ -> fail "geckodriver on PATH must be found"))

(* The lane takes absolute paths only, so a program found through a relative
   PATH entry, or named by a relative path, is reported where it is on disk. *)
let test_a_relative_path_is_reported_by_its_absolute_path () =
  with_executable ~name:"geckodriver" "#!/bin/sh\necho 'geckodriver 4.5.6'\n"
    (fun dir _ ->
       with_cwd dir (fun () ->
         let expect_absolute label = function
           | B.Started {path; _} ->
             check bool (label ^ ": absolute") false (Filename.is_relative path);
             check bool (label ^ ": the file that answered exists") true (Sys.file_exists path);
             check string (label ^ ": names the program") "geckodriver" (Filename.basename path)
           | B.Missing _ | B.Failed _ -> fail (label ^ ": must start") in
         expect_absolute "relative command" (B.probe "./geckodriver");
         with_env "PATH" ".:/usr/bin:/bin" (fun () ->
           expect_absolute "relative PATH entry" (B.observe B.Geckodriver))))

(* A shell searching PATH skips a file it may not execute, and so does the
   check: such a file is not a program, and a directory is not one either. *)
(* Whether a program is there is a question the file answers. Asking it by
   starting the program would run the operator's program to learn that it
   exists, and a launcher may open a window. *)
let test_locate_finds_a_program_without_starting_it () =
  with_directory (fun dir ->
    let marker = Filename.concat dir "was-run" in
    let path =
      write_program dir "geckodriver" (Printf.sprintf "#!/bin/sh\ntouch '%s'\n" marker)
    in
    check (option string) "an absolute path is located as written" (Some path) (B.locate path);
    let inherited = Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin" in
    with_env "PATH" (dir ^ ":" ^ inherited) (fun () ->
      check (option string) "a name is located on PATH" (Some path) (B.locate "geckodriver"));
    check bool "the program was not started" false (Sys.file_exists marker);
    (* The same program started by probe does leave the marker: the check above
       sees a start if there were one. *)
    ignore (B.probe path);
    check bool "probe starts it" true (Sys.file_exists marker))

let test_locate_is_none_for_what_cannot_run () =
  with_directory (fun dir ->
    let plain = write_program ~mode:0o644 dir "geckodriver" "#!/bin/sh\necho x\n" in
    let folder = Filename.concat dir "firefox" in
    Unix.mkdir folder 0o700;
    List.iter (fun candidate ->
      check (option string) candidate None (B.locate candidate))
      [ plain; folder; Filename.concat dir "absent"; "/nonexistent-dir/geckodriver"; "" ])

let test_a_file_that_cannot_be_executed_is_missing () =
  with_directory (fun dir ->
    let plain = write_program ~mode:0o644 dir "geckodriver" "#!/bin/sh\necho x\n" in
    let folder = Filename.concat dir "firefox" in
    Unix.mkdir folder 0o700;
    List.iter (fun candidate ->
      match B.probe candidate with
      | B.Missing _ -> ()
      | B.Started _ | B.Failed _ -> fail "something that cannot run is not a program")
      [plain; folder])

(* Started beats Failed beats Missing, and the walk ends at the first answer so
   that a launcher listed after it is never run. *)
let test_the_first_program_that_answers_ends_the_walk () =
  with_directory (fun dir ->
    let broken = write_program dir "broken" "#!/bin/sh\necho broken >&2\nexit 3\n" in
    let good = write_program dir "good" "#!/bin/sh\necho 'fx 1.0'\n" in
    let marker = Filename.concat dir "later-ran" in
    let later =
      write_program dir "later"
        (Printf.sprintf "#!/bin/sh\n: > %s\necho later\n" (Filename.quote marker)) in
    let absent = Filename.concat dir "absent" in
    let other_absent = Filename.concat dir "other-absent" in
    (match B.first_answer ~label:"fx" [absent; broken; good; later] with
     | B.Started {path; _} -> check string "the first program that answers" good path
     | B.Missing _ | B.Failed _ -> fail "an answering program must win over a failure");
    check bool "a later candidate is never started" false (Sys.file_exists marker);
    (match B.first_answer ~label:"fx" [absent; broken; other_absent] with
     | B.Failed {path; _} -> check string "a failure outranks a missing file" broken path
     | B.Missing _ | B.Started _ -> fail "a failure must outrank a missing file");
    (match B.first_answer ~label:"fx" [absent; other_absent] with
     | B.Missing command -> check string "the first candidate is named" absent command
     | B.Started _ | B.Failed _ -> fail "nothing exists, so it is missing");
    (match B.first_answer ~label:"fx" [] with
     | B.Missing command -> check string "an empty list names the program" "fx" command
     | B.Started _ | B.Failed _ -> fail "no candidate is missing"))

(* Firefox on macOS is inside its application bundle, system-wide or in the
   user's own Applications folder. A HOME that is not absolute lists nothing
   that would only mean something from one directory. *)
let test_firefox_bundle_locations_follow_an_absolute_home () =
  with_env "HOME" "/Users/fixture" (fun () ->
    check bool "the user's Applications folder is listed" true
      (List.mem "/Users/fixture/Applications/Firefox.app/Contents/MacOS/firefox"
         (B.candidates B.Firefox)));
  List.iter (fun home ->
    with_env "HOME" home (fun () ->
      check bool "only absolute bundle locations" true
        (List.for_all (fun c -> String.equal c "firefox" || not (Filename.is_relative c))
           (B.candidates B.Firefox))))
    [""; "relative/home"];
  check (list string) "geckodriver is a bare name" ["geckodriver"] (B.candidates B.Geckodriver);
  with_env "HOME" "/Users/fixture" (fun () ->
    check (list string) "ego-browser on PATH, then where ego lite's onboarding links it"
      ["ego-browser"; "/Users/fixture/.local/bin/ego-browser"] (B.candidates B.Ego_browser));
  List.iter (fun home ->
    with_env "HOME" home (fun () ->
      check (list string) "no relative place for ego-browser" ["ego-browser"] (B.candidates B.Ego_browser)))
    [""; "relative/home"]

(* Same words as the PDF and presentation checks, because one reader walks all
   three. *)
let test_the_readiness_json_uses_the_shared_status_words () =
  with_executable ~name:"geckodriver" "#!/bin/sh\necho 'geckodriver 7.7.7'\n"
    (fun _ path ->
       let json = B.to_json B.Geckodriver (B.probe path) in
       let member key value = Yojson.Safe.Util.member key value in
       check string "schema" "masc.browser_tools_readiness.v1"
         (Yojson.Safe.Util.to_string (member "schema" json));
       check string "available" "tools_available"
         (Yojson.Safe.Util.to_string (member "status" json));
       match Yojson.Safe.Util.to_list (member "checks" json) with
       | [row] ->
         check string "row status" "started" (Yojson.Safe.Util.to_string (member "status" row));
         check string "row path" path (Yojson.Safe.Util.to_string (member "path" row))
       | _ -> fail "one program is one row");
  let missing = B.to_json B.Firefox (B.Missing "firefox") in
  check string "unavailable" "unavailable"
    (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "status" missing))

(* Hearing is the only half of voice a fresh mac cannot already do: say is in
   the base system with nine Korean voices, and nothing transcribes. What the
   catalog offers for that was measured 2026-09-12 -- the brew bottle is 8.9MB,
   and the model at this URL answered 200 with content-length 1,624,555,275. *)
let whisper host distribution = P.catalog ~host ~distribution P.Whisper_cli

(* A fresh mac has no Homebrew, and two of the hearing steps are Homebrew
   steps. Measured before this: the receipt said the step "did not finish" and
   to check its terminal output, when brew had never run and there was none. *)
let test_a_missing_homebrew_is_named_with_where_it_comes_from () =
  let actions = whisper (mac S.Arm64 26) P.Other in
  let reason_of id failure =
    match P.execute ~run:(fun _ -> Error failure) (find id actions) with
    | P.Failed {step = 1; reason} -> reason
    | _ -> fail "a failed first step must be reported as step 1"
  in
  let homebrew = reason_of "sox_brew_install" P.Program_not_found in
  check bool (Printf.sprintf "names Homebrew (%s)" homebrew) true
    (String_util.contains_substring homebrew "Homebrew is not installed");
  check bool "and where it comes from" true
    (String_util.contains_substring homebrew "https://brew.sh");
  check bool "and does not send the reader to output that does not exist" false
    (String_util.contains_substring homebrew "terminal output")

let test_a_missing_program_that_is_not_homebrew_is_named_as_itself () =
  let actions =
    P.catalog ~model_dir:"/somewhere/cache/whisper" ~host:(mac S.Arm64 26)
      ~distribution:P.Other P.Whisper_cli
  in
  (match P.execute ~run:(fun _ -> Error P.Program_not_found) (find "whisper_model_download" actions) with
   | P.Failed {reason; _} ->
     check bool (Printf.sprintf "names curl (%s)" reason) true
       (String_util.contains_substring reason "curl is not on PATH");
     check bool "and not Homebrew" false (String_util.contains_substring reason "Homebrew")
   | _ -> fail "a missing program must fail the step");
  match P.execute ~run:(fun _ -> Error P.Could_not_start) (find "whisper_cli_brew_install" actions) with
  | P.Failed {reason; _} ->
    check bool (Printf.sprintf "a program that would not start is named (%s)" reason) true
      (String_util.contains_substring reason "brew could not be started")
  | _ -> fail "a program that could not start must fail the step"

let test_whisper_offers_a_package_and_a_model () =
  let actions =
    P.catalog ~model_dir:"/somewhere/cache/whisper" ~host:(mac S.Arm64 26)
      ~distribution:P.Other P.Whisper_cli
  in
  check int "a transcriber, a model, and a recorder" 3 (List.length actions);
  (* Where the model lands is stated, not left to be read out of argv: the fetch
     goes to a .part and is moved, so the -o argument is not the file. *)
  check (option string) "the download states the final path it writes"
    (Some "/somewhere/cache/whisper/ggml-large-v3-turbo.bin")
    (find "whisper_model_download" actions).writes;
  check (option string) "an install writes no file a reader needs"
    None (find "whisper_cli_brew_install" actions).writes;
  (match (find "whisper_cli_brew_install" actions).action_effect with
   | P.Run_commands steps ->
     check (list (list string)) "the formula, installed and not started"
       [ [ "brew"; "install"; "whisper-cpp" ] ] steps
   | _ -> fail "the package step must run a command");
  match (find "whisper_model_download" actions).action_effect with
  | P.Run_commands [ fetch; publish ] ->
    (* --create-dirs because the cache directory will not exist on a machine
       that has never had one, and the whole path is one argv item: no shell
       expands a ~ here.

       -f because without it an HTTP error body is written under the model's
       name and curl still exits 0, so the plan reports the prerequisite done
       and leaves an error page where whisper expects 1.6GB of model.

       Fetched beside the final path and moved after: a run that dies part
       way then leaves nothing at the path the voice configuration names. *)
    check (list string) "the model, fetched to where it was told"
      [ "curl"
      ; "-fL"
      ; "--create-dirs"
      ; "-o"
      ; "/somewhere/cache/whisper/ggml-large-v3-turbo.bin.part"
      ; "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
      ]
      fetch;
    check (list string) "and published only once it arrived"
      [ "mv"
      ; "/somewhere/cache/whisper/ggml-large-v3-turbo.bin.part"
      ; "/somewhere/cache/whisper/ggml-large-v3-turbo.bin"
      ]
      publish
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
    fail "the model step must fetch beside the path and then publish"

(* Offering a download with nowhere to write would produce a command that
   fails on a path nobody chose. The page is opened instead. *)
let test_without_a_directory_the_model_is_a_page_not_a_command () =
  let actions = whisper (mac S.Arm64 26) P.Other in
  match (find "whisper_model_page" actions).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
    fail "with no directory there is no download command to offer"

(* Homebrew is the only route this catalog can name a command for. Naming an
   apt package would install whatever happens to carry that name, or nothing. *)
let test_linux_gets_instructions_rather_than_a_guessed_package () =
  List.iter
    (fun distribution ->
      let actions = whisper (S.Linux S.X64) distribution in
      (* Three now: the binary, the model, and the recorder. The branch named
         the binary and stopped, so an operator who followed this plan to its
         end still had nothing for -m. The first two are links here because no
         cache directory was given and because whisper.cpp is not packaged. *)
      check int "three actions" 3 (List.length actions);
      List.iter
        (fun id ->
          match (find id actions).action_effect with
          | P.Open_official_installer _ -> ()
          | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
            fail "no package name is guessed for whisper.cpp on Linux")
        [ "whisper_cli_build_instructions"; "whisper_model_page" ])
    [ P.Debian; P.Ubuntu; P.Other ]

(* The rule above is about whisper.cpp, which is built rather than packaged.
   sox is packaged, so naming it is not a guess -- but only where the package
   manager is known. Elsewhere it is a link for the same reason whisper is. *)
let test_the_recorder_is_named_where_the_package_manager_is_known () =
  List.iter
    (fun distribution ->
      let actions = whisper (S.Linux S.X64) distribution in
      match (find "sox_apt_install" actions).action_effect with
      | P.Run_commands steps ->
        check (list (list string)) "the package, installed"
          [ [ "apt-get"; "install"; "-y"; "sox" ] ] steps
      | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
        fail "a known package manager can name the package")
    [ P.Debian; P.Ubuntu ];
  match (find "sox_project_page" (whisper (S.Linux S.X64) P.Other)).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
    fail "an unknown distribution gets a link, not a guessed package"

(* Transcribing a file and making one are different halves, and only the first
   was named. masc records with sox's rec and marks the start and end of a
   recording with sox's play; without them a capture fails on its own process
   error and the tones are swallowed at debug level, so nothing on the way in
   says a package is missing. *)
let test_hearing_names_the_recorder_not_only_the_transcriber () =
  match (find "sox_brew_install" (whisper (mac S.Arm64 26) P.Other)).action_effect with
  | P.Run_commands steps ->
    check (list (list string)) "the formula that carries rec and play"
      [ [ "brew"; "install"; "sox" ] ] steps
  | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
    fail "Homebrew can name this one"


(* The model step is written once and used by both hosts. Left per-host, the
   Linux branch went without one -- which is the gap this pins. *)
let test_linux_with_a_cache_gets_the_same_download () =
  let actions =
    P.catalog ~model_dir:"/var/cache/whisper" ~host:(S.Linux S.X64)
      ~distribution:P.Other P.Whisper_cli
  in
  match (find "whisper_model_download" actions).action_effect with
  | P.Run_commands [ fetch; publish ] ->
    check (list string) "the same fetch macOS gets"
      [ "curl"
      ; "-fL"
      ; "--create-dirs"
      ; "-o"
      ; "/var/cache/whisper/ggml-large-v3-turbo.bin.part"
      ; "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
      ]
      fetch;
    check (list string) "and the same publish"
      [ "mv"
      ; "/var/cache/whisper/ggml-large-v3-turbo.bin.part"
      ; "/var/cache/whisper/ggml-large-v3-turbo.bin"
      ]
      publish
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
    fail "linux with a cache directory must get the download too"

let apple_catalog apple_builder =
  P.catalog ~apple_builder ~host:(mac S.Arm64 26) ~distribution:P.Other (P.Sandbox S.Apple_container)
let needs_rosetta user_config = P.Needs_missing_rosetta {user_config}

(* A running Apple Container whose image builder needs a Rosetta this Mac does
   not have is missing one thing. The operator chooses how past it; the
   installers for a service that already answered are not offered. *)
let test_a_builder_without_rosetta_offers_the_two_ways_past_it () =
  let ids apple_builder = List.map (fun (action : P.action) -> action.id) (apple_catalog apple_builder) in
  check (list string) "building without Rosetta, then installing it"
    ["apple_container_build_without_rosetta"; "rosetta_install"]
    (ids (needs_rosetta (Some "/Users/u/.config/container/config.toml")));
  check (list string) "with nowhere to record the setting, installing Rosetta remains"
    ["rosetta_install"] (ids (needs_rosetta None));
  check (list string) "an unchecked builder keeps the installers"
    ["apple_container_official_install"; "apple_container_start"] (ids P.Builder_unchecked);
  let install = find "rosetta_install" (apple_catalog (needs_rosetta None)) in
  check bool "installing Rosetta discloses administrator permission" true install.requires_admin;
  (match install.action_effect with
   | P.Run_commands steps ->
     check (list (list string)) "Apple's installer, which shows its license to the operator"
       [["softwareupdate";"--install-rosetta"]] steps
   | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
     fail "installing Rosetta is not the installer page");
  let without = find "apple_container_build_without_rosetta"
      (apple_catalog (needs_rosetta (Some "/Users/u/.config/container/config.toml"))) in
  check bool "building without Rosetta needs no administrator" false without.requires_admin;
  check (option string) "the file it writes is published" (Some "/Users/u/.config/container/config.toml") without.writes

(* A builder whose VM starts but boots no kernel is missing exactly the
   kernel: the one action sets Apple's recommended one as the default, without
   administrator permission, and the service's installers are not reoffered. *)
let test_a_builder_without_a_default_kernel_offers_to_install_it () =
  let ids = List.map (fun (action : P.action) -> action.id) (apple_catalog P.Needs_default_kernel) in
  check (list string) "installing the recommended kernel is the one action"
    ["apple_container_kernel_set"] ids;
  let install = find "apple_container_kernel_set" (apple_catalog P.Needs_default_kernel) in
  check bool "the kernel download needs no administrator permission" false install.requires_admin;
  (match install.action_effect with
   | P.Run_commands steps ->
     check (list (list string)) "Apple's recommended kernel, set as the default"
       [["container";"system";"kernel";"set";"--recommended"]] steps
   | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ | P.Run_searxng _ | P.Start_existing_searxng ->
     fail "the kernel action is not a command")

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let read path = In_channel.with_open_text path In_channel.input_all
let write path contents = Out_channel.with_open_text path (fun out -> output_string out contents)
let restart = [["container";"system";"stop"];["container";"system";"start"]]
let build_without_rosetta user_config =
  find "apple_container_build_without_rosetta" (apple_catalog (needs_rosetta (Some user_config)))
let rosetta_setting path =
  match Otoml.Parser.from_string_result (read path) with
  | Ok document -> Otoml.find_opt document (fun value -> Otoml.get_boolean value) ["build"; "rosetta"]
  | Error _ -> None

(* The setting is one line in a file the operator owns, so the edit leaves every
   other line where it was, keeps a dotfile manager's symlink a symlink, refuses
   a file Apple Container could not read either, and only then restarts the
   service that reads it. *)
let test_building_without_rosetta_writes_one_line_then_restarts () =
  let dir = Filename.temp_dir "masc-container-config-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let calls = ref [] in
  let recording argv = calls := argv :: !calls; Ok () in
  let fresh = Filename.concat (Filename.concat (Filename.concat dir "fresh") "container") "config.toml" in
  check bool "a restarted service still needs a recheck" true
    (P.execute ~run:recording (build_without_rosetta fresh) = P.Commands_completed_recheck_required);
  check (option bool) "a file that did not exist now holds the setting" (Some false) (rosetta_setting fresh);
  check (list (list string)) "the service restarts after the write, stopping before starting"
    restart (List.rev !calls);
  let existing = Filename.concat dir "config.toml" in
  let before = "# kept as written\n[container]\ncpus = 4\n\n[build]\n# why this builder\nrosetta = true\nmemory = \"2048mb\"\n" in
  write existing before;
  ignore (P.execute ~run:(fun _ -> Ok ()) (build_without_rosetta existing));
  check string "only the rosetta line changed"
    "# kept as written\n[container]\ncpus = 4\n\n[build]\n# why this builder\nrosetta = false\nmemory = \"2048mb\"\n"
    (read existing);
  let managed = Filename.concat dir "managed.toml" in
  write managed "[build]\nrosetta = true\n";
  let link = Filename.concat dir "linked.toml" in
  Unix.symlink managed link;
  ignore (P.execute ~run:(fun _ -> Ok ()) (build_without_rosetta link));
  check bool "the link is still a link" true ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
  check (option bool) "the link's target holds the setting" (Some false) (rosetta_setting managed);
  let dangling = Filename.concat dir "dangling.toml" in
  let not_yet = Filename.concat dir "not-yet-created.toml" in
  Unix.symlink not_yet dangling;
  ignore (P.execute ~run:(fun _ -> Ok ()) (build_without_rosetta dangling));
  check bool "a link to a file not yet created is still a link" true ((Unix.lstat dangling).Unix.st_kind = Unix.S_LNK);
  check (option bool) "and the file it names now holds the setting" (Some false) (rosetta_setting not_yet);
  let restricted = Filename.concat dir "restricted.toml" in
  write restricted "[build]\nrosetta = true\n";
  Unix.chmod restricted 0o640;
  ignore (P.execute ~run:(fun _ -> Ok ()) (build_without_rosetta restricted));
  check int "the file keeps the permissions it had" 0o640 ((Unix.stat restricted).Unix.st_perm);
  let broken = Filename.concat dir "broken.toml" in
  write broken "[build\nrosetta = true\n";
  let restarted = ref 0 in
  (match P.execute ~run:(fun _ -> incr restarted; Ok ()) (build_without_rosetta broken) with
   | P.Failed {step=1; _} -> ()
   | P.Failed _ | P.External_step_pending | P.Commands_completed_recheck_required ->
     fail "a file that is not TOML is refused at the write");
  check string "the refused file is untouched" "[build\nrosetta = true\n" (read broken);
  check int "nothing restarts after a refused write" 0 !restarted;
  match P.execute ~run:(fun _ -> Error P.Did_not_finish) (build_without_rosetta existing) with
  | P.Failed {step=2; _} -> ()
  | P.Failed _ | P.External_step_pending | P.Commands_completed_recheck_required ->
    fail "a stop that did not finish is the step after the write"

(* SearXNG: one key-free search provider, run in a container the operator's
   Docker provides. The plan depends on what Docker says about the container,
   and the settings file is the operator's once it exists. *)
module R = Masc.Searxng_runtime_dependency

let searxng ~config_dir = P.Searxng {config_dir}
let searxng_actions ?(container = P.Searxng_absent) host config_dir =
  P.catalog ~searxng_container:container ~host ~distribution:P.Other (searxng ~config_dir)

let test_searxng_plan_follows_the_container () =
  List.iter (fun host ->
    let absent = searxng_actions host "/work/.masc/searxng" in
    (match absent with
     | [action] ->
       check string "id" "searxng_docker_run" action.id;
       check (option string) "the file it leaves" (Some "/work/.masc/searxng/settings.yml") action.writes;
       check bool "no privilege" false action.requires_admin;
       (match action.action_effect with
        | P.Run_searxng {config_dir} -> check string "dir" "/work/.masc/searxng" config_dir
        | _ -> fail "expected the run effect for an absent container");
       let json = Yojson.Safe.to_string (P.to_json absent) in
       check bool "pinned image" true (String_util.contains_substring json P.searxng_image);
       check bool "image is a dated tag, not latest" false (String_util.contains_substring P.searxng_image ":latest");
       check bool "the tag is held by the digest it resolved to" true
         (String_util.contains_substring P.searxng_image "@sha256:");
       check bool "the restart policy is said where the reader decides" true
         (String_util.contains_substring action.detail "--restart unless-stopped");
       check bool "the anonymous cache volume is said" true
         (String_util.contains_substring action.detail "anonymously");
       check bool "published on loopback only" true (String_util.contains_substring json "127.0.0.1:8888:8080");
       check bool "settings mounted read-only" true
         (String_util.contains_substring json "/work/.masc/searxng:/etc/searxng:ro")
     | _ -> fail "one action for an absent container");
    (match searxng_actions ~container:P.Searxng_stopped host "/work/.masc/searxng" with
     | [action] ->
       check string "id" "searxng_docker_start_existing" action.id;
       check bool "starts the container by name" true
         (String_util.contains_substring (Yojson.Safe.to_string (P.to_json [action])) "\"docker\",\"start\",\"masc-searxng\"");
       (* The container keeps what it was created with, so the plan names no
          file it will not write and no address it did not choose. *)
       check (option string) "a stopped container's start writes nothing" None action.writes;
       check bool "no settings file in the effect" true
         (Yojson.Safe.Util.member "settings_file"
            (Yojson.Safe.Util.member "effect" (List.hd (Yojson.Safe.Util.to_list
               (Yojson.Safe.Util.member "actions" (P.to_json [action]))))) = `Null);
       check bool "does not claim the address it did not set" false
         (String_util.contains_substring action.detail "127.0.0.1")
     | _ -> fail "one action for a stopped container");
    List.iter (fun (what, container) ->
      check int (what ^ " has no action to offer") 0
        (List.length (searxng_actions ~container host "/work/.masc/searxng")))
      [ "a running container", P.Searxng_running; "a paused container", P.Searxng_paused
      ; "a restarting container", P.Searxng_restarting
      ; "a dead container", P.Searxng_unusable "dead" ])
    [mac S.Arm64 26; mac S.X64 14; S.Linux S.X64];
  check int "an unsupported host is offered nothing" 0
    (List.length (searxng_actions S.Unsupported "/work/.masc/searxng"))

let test_searxng_settings_turn_json_on_and_hold_the_key () =
  let text = P.searxng_settings ~secret_key:"k-123" in
  check bool "JSON format on" true (String_util.contains_substring text "    - json");
  check bool "html stays" true (String_util.contains_substring text "    - html");
  check bool "limiter off" true (String_util.contains_substring text "limiter: false");
  check bool "the key is the one given" true (String_util.contains_substring text "secret_key: \"k-123\"");
  (* granian binds from its own environment; these two settings only apply to
     a direct `python searx/webapp.py` run, so they are not written. *)
  check bool "no bind_address: granian binds from GRANIAN_HOST" false (String_util.contains_substring text "bind_address");
  check bool "no port line: granian binds from GRANIAN_PORT" false (String_util.contains_substring text "port:")

let test_searxng_writes_the_settings_once_and_keeps_an_edit () =
  let dir = Filename.temp_dir "masc-searxng-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let config_dir = Filename.concat (Filename.concat dir ".masc") "searxng" in
  let action = List.hd (searxng_actions (mac S.Arm64 26) config_dir) in
  let calls = ref [] in
  let recording argv = calls := argv :: !calls; Ok () in
  check bool "commands finished needs a recheck" true
    (P.execute ~run:recording action = P.Commands_completed_recheck_required);
  let path = Filename.concat config_dir "settings.yml" in
  let first = read path in
  check bool "JSON on" true (String_util.contains_substring first "    - json");
  check int "owner-only: the file holds the key" 0o600 ((Unix.stat path).Unix.st_perm land 0o777);
  check (list (list string)) "pull, then run"
    [ ["docker";"pull";P.searxng_image]
    ; ["docker";"run";"--detach";"--name";"masc-searxng";"--restart";"unless-stopped";
       "--cap-drop";"ALL";"--security-opt";"no-new-privileges:true";
       "--publish";"127.0.0.1:8888:8080";"--volume";config_dir ^ ":/etc/searxng:ro";P.searxng_image] ]
    (List.rev !calls);
  (* An operator's edit survives the next run, and the key does not change. *)
  write path (first ^ "# turned an engine off by hand\n");
  calls := [];
  ignore (P.execute ~run:recording action);
  check string "the file is kept as the operator left it" (first ^ "# turned an engine off by hand\n") (read path);
  (* Another install does not share the key. *)
  let other_dir = Filename.concat dir "other" in
  ignore (P.execute ~run:recording (List.hd (searxng_actions (mac S.Arm64 26) other_dir)));
  check bool "keys differ between installs" false
    (String.equal (read (Filename.concat other_dir "settings.yml")) first)

let test_searxng_stops_at_the_first_failing_step () =
  let dir = Filename.temp_dir "masc-searxng-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let action = List.hd (searxng_actions (S.Linux S.X64) (Filename.concat dir "s")) in
  let calls = ref [] in
  let failing argv = calls := argv :: !calls; Error P.Did_not_finish in
  (match P.execute ~run:failing action with
   | P.Failed {step; _} -> check int "the pull is step 2: the file was step 1" 2 step
   | _ -> fail "expected a failure at the pull");
  check int "the run is not tried" 1 (List.length !calls);
  (* A directory that cannot be created is the first step's failure. *)
  let blocker = Filename.concat dir "blocker" in
  write blocker "a file where a directory has to be";
  let under_file = List.hd (searxng_actions (S.Linux S.X64) (Filename.concat blocker "s")) in
  calls := [];
  (match P.execute ~run:(fun argv -> calls := argv :: !calls; Ok ()) under_file with
   | P.Failed {step; _} -> check int "file step" 1 step
   | _ -> fail "expected the write to fail");
  check int "no docker step ran" 0 (List.length !calls)

let test_searxng_readiness_reads_docker_container_and_endpoint () =
  let run_up status = fun argv ->
    match argv with
    | "docker" :: "info" :: _ -> Ok "29.4.3"
    | "docker" :: "inspect" :: _ -> (match status with Some s -> Ok (s ^ "\n") | None -> Error ())
    | _ -> Error () in
  let answers = fun _ -> Ok (Some 200, {|{"query":"masc","results":[],"unresponsive_engines":[]}|}) in
  let check_of ?(run = run_up (Some "running")) ?(get = answers) () = R.observe ~run ~get () in
  let c = check_of () in
  check bool "docker" true c.docker;
  check bool "running" true (c.container = P.Searxng_running);
  check bool "an empty result list still answers" true (c.endpoint = R.Answers);
  check bool "available" true (R.available c);
  check bool "an exited container is stopped" true
    ((check_of ~run:(run_up (Some "exited")) ()).container = P.Searxng_stopped);
  check bool "a created container is stopped: docker start runs it" true
    ((check_of ~run:(run_up (Some "created")) ()).container = P.Searxng_stopped);
  check bool "a paused container is not one that start can run" true
    ((check_of ~run:(run_up (Some "paused")) ()).container = P.Searxng_paused);
  check bool "a restarting container is its own state" true
    ((check_of ~run:(run_up (Some "restarting")) ()).container = P.Searxng_restarting);
  check bool "a dead container is unusable and keeps Docker's word" true
    ((check_of ~run:(run_up (Some "dead")) ()).container = P.Searxng_unusable "dead");
  check bool "a status word nobody here knows is not read as stopped" true
    ((check_of ~run:(run_up (Some "reconfiguring")) ()).container = P.Searxng_unusable "reconfiguring");
  check bool "no such container is absent" true
    ((check_of ~run:(run_up None) ()).container = P.Searxng_absent);
  let down = check_of ~run:(fun _ -> Error ()) () in
  check bool "docker down" false down.docker;
  check bool "an instance run another way still counts" true (R.available down);
  check bool "403 means JSON is off" true
    ((check_of ~get:(fun _ -> Ok (Some 403, "")) ()).endpoint = R.Refuses_json);
  check bool "an HTML page is not a result object" true
    ((check_of ~get:(fun _ -> Ok (Some 200, "<html></html>")) ()).endpoint = R.Refuses_json);
  check bool "a JSON object without results is not an answer" true
    ((check_of ~get:(fun _ -> Ok (Some 200, {|{"error":"nope"}|})) ()).endpoint = R.Refuses_json);
  check bool "results without the envelope is another program answering" true
    ((check_of ~get:(fun _ -> Ok (Some 200, {|{"results":[]}|})) ()).endpoint = R.Refuses_json);
  check bool "dead engines still answer: the endpoint serves" true
    ((check_of ~get:(fun _ -> Ok (Some 200, {|{"query":"masc","results":[],"unresponsive_engines":[["brave","suspended"]]}|})) ())
       .endpoint
     = R.Answers);
  check bool "another status is unreachable" true
    ((check_of ~get:(fun _ -> Ok (Some 500, "")) ()).endpoint = R.Unreachable);
  check bool "a transport failure is unreachable" true
    ((check_of ~get:(fun _ -> Error "curl exit 7") ()).endpoint = R.Unreachable);
  let asked = ref "" in
  ignore (R.observe ~run:(run_up (Some "running")) ~get:(fun url -> asked := url; Ok (Some 200, "{}")) ());
  check string "asks the address the container is published on, for JSON"
    "http://127.0.0.1:8888/search?q=masc&format=json" !asked;
  check string "the address is the published one" "http://127.0.0.1:8888" R.default_url;
  check string "the default URL names the published address, not localhost"
    "http://127.0.0.1:8888" Masc_network_defaults.searxng_default_url;
  let unusable = R.to_json (check_of ~run:(run_up (Some "dead")) ()) in
  check bool "the container word is a closed one" true
    (Yojson.Safe.Util.member "container" unusable = `String "unusable");
  check bool "Docker's own word is kept beside it" true
    (Yojson.Safe.Util.member "docker_status" unusable = `String "dead");
  check bool "no Docker word for a state with a name" true
    (Yojson.Safe.Util.member "docker_status" (R.to_json (check_of ())) = `Null);
  let json = R.to_json down in
  check bool "status words are the shared ones" true
    (Yojson.Safe.Util.member "status" json = `String "ready");
  check bool "unavailable is spelled out" true
    (Yojson.Safe.Util.member "status" (R.to_json (check_of ~get:(fun _ -> Error "x") ())) = `String "unavailable")

let test_searxng_starts_a_stopped_container_and_writes_nothing () =
  let dir = Filename.temp_dir "masc-searxng-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let config_dir = Filename.concat dir "searxng" in
  let action = List.hd (searxng_actions ~container:P.Searxng_stopped (mac S.Arm64 26) config_dir) in
  let calls = ref [] in
  check bool "commands finished needs a recheck" true
    (P.execute ~run:(fun argv -> calls := argv :: !calls; Ok ()) action = P.Commands_completed_recheck_required);
  check (list (list string)) "docker start and nothing else" [["docker";"start";"masc-searxng"]] (List.rev !calls);
  check bool "no settings directory was made for a mount it may not have" false (Sys.file_exists config_dir);
  match P.execute ~run:(fun _ -> Error P.Did_not_finish) action with
  | P.Failed {step; _} -> check int "the start is step 1: no file was step 1" 1 step
  | _ -> fail "expected the start to fail"

let test_searxng_refuses_a_settings_path_that_is_not_a_file () =
  let dir = Filename.temp_dir "masc-searxng-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let calls = ref [] in
  let run argv = calls := argv :: !calls; Ok () in
  let refused config_dir =
    calls := [];
    match P.execute ~run (List.hd (searxng_actions (S.Linux S.X64) config_dir)) with
    | P.Failed {step = 1; reason} -> check int "no docker step ran" 0 (List.length !calls); reason
    | _ -> fail "expected the settings path to be refused" in
  (* A directory named settings.yml is not a settings file: kept, the
     container exits on it. *)
  let with_directory = Filename.concat dir "dir" in
  Unix.mkdir with_directory 0o700;
  Unix.mkdir (Filename.concat with_directory "settings.yml") 0o700;
  check bool "a directory is named" true
    (String_util.contains_substring (refused with_directory) "is not a regular file");
  (* A link that leads nowhere is the operator's: it is neither kept nor replaced. *)
  let with_link = Filename.concat dir "link" in
  Unix.mkdir with_link 0o700;
  let link = Filename.concat with_link "settings.yml" in
  Unix.symlink (Filename.concat dir "nowhere") link;
  check bool "a dangling link is named" true
    (String_util.contains_substring (refused with_link) "leads nowhere");
  check string "the link is still the operator's" (Filename.concat dir "nowhere") (Unix.readlink link);
  (* A link to a real file is a settings file, and is kept. *)
  let target = Filename.concat dir "real.yml" in
  write target "use_default_settings: true\n";
  let kept = Filename.concat dir "kept" in
  Unix.mkdir kept 0o700;
  Unix.symlink target (Filename.concat kept "settings.yml");
  calls := [];
  check bool "a link to a file is kept and the run goes on" true
    (P.execute ~run (List.hd (searxng_actions (S.Linux S.X64) kept)) = P.Commands_completed_recheck_required);
  check string "its target is untouched" "use_default_settings: true\n" (read target)

let test_searxng_docker_probes_are_bounded () =
  (* A Docker that does not answer must not hold the catalog print: the probe
     carries the same read-bucket bound Sandbox_readiness puts on its own
     docker info. The stand-in sleeps far longer than the bound. *)
  let dir = Filename.temp_dir "masc-searxng-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  let docker = Filename.concat dir "docker" in
  write docker "#!/bin/sh\nexec sleep 60\n";
  Unix.chmod docker 0o755;
  let variable = "MASC_KEEPER_SHELL_TIMEOUT_READ_SEC" in
  let old_path = Sys.getenv_opt "PATH" and old_bound = Sys.getenv_opt variable in
  let restore name = function Some v -> Unix.putenv name v | None -> Unix.putenv name "" in
  Fun.protect ~finally:(fun () -> restore "PATH" old_path; restore variable old_bound) @@ fun () ->
  Unix.putenv "PATH" (dir ^ ":/usr/bin:/bin");
  Unix.putenv variable "1";
  let started = Unix.gettimeofday () in
  let container = R.container () in
  let elapsed = Unix.gettimeofday () -. started in
  check bool "a Docker that never answers is a Docker that is down" true (container = P.Searxng_absent);
  check bool (Printf.sprintf "answered within the bound, not after sixty seconds (%.1fs)" elapsed) true (elapsed < 20.0)

let test_searxng_waits_for_a_container_that_is_still_starting () =
  let looks = ref 0 and sleeps = ref 0 in
  let run = fun _ -> Error () in
  let get = fun _ -> incr looks;
    if !looks < 3 then Error "curl exit 7"
    else Ok (Some 200, {|{"query":"masc","results":[],"unresponsive_engines":[]}|}) in
  let c = R.wait_until_available ~attempts:10 ~pause_sec:0.0 ~sleep:(fun _ -> incr sleeps) ~run ~get () in
  check bool "answered" true (R.available c);
  check int "three looks" 3 !looks;
  check int "slept between looks only" 2 !sleeps;
  looks := 0; sleeps := 0;
  let never = R.wait_until_available ~attempts:4 ~pause_sec:0.0 ~sleep:(fun _ -> incr sleeps) ~run
      ~get:(fun _ -> incr looks; Error "curl exit 7") () in
  check bool "gave up" false (R.available never);
  check int "bounded looks" 4 !looks;
  check int "no sleep after the last look" 3 !sleeps

let test_searxng_settings_match_the_helper_script () =
  (* scripts/searxng-local.sh predates the catalog and writes its own copy of
     the settings body (#43181 item 1). The two spellings must stay
     byte-equal for the same key; this test reads the script's heredoc and
     compares it against the catalog text. *)
  let script =
    Filename.concat (Masc_test_deps.find_project_root ()) "scripts/searxng-local.sh" in
  let lines = String.split_on_char '\n' (read script) in
  let rec heredoc = function
    | line :: rest when String.trim line = "cat >\"$settings\" <<EOF" ->
      let rec take acc = function
        | [] -> fail "searxng-local.sh: unterminated settings heredoc"
        | "EOF" :: _ -> List.rev acc
        | line :: rest -> take (line :: acc) rest in
      take [] rest
    | _ :: rest -> heredoc rest
    | [] -> fail "searxng-local.sh: settings heredoc not found" in
  let replace_secret line =
    let needle = "$secret" in
    let nlen = String.length needle and llen = String.length line in
    let buf = Buffer.create llen in
    let rec go i =
      if i + nlen <= llen && String.equal (String.sub line i nlen) needle then (
        Buffer.add_string buf "k-123"; go (i + nlen))
      else if i < llen then (Buffer.add_char buf line.[i]; go (i + 1)) in
    go 0;
    Buffer.contents buf in
  let body_lines = List.map replace_secret (heredoc lines) in
  List.iter
    (fun line ->
      check bool ("no unexpanded variable left in: " ^ line) false
        (String.contains line '$'))
    body_lines;
  check string "the script and the catalog write the same settings"
    (P.searxng_settings ~secret_key:"k-123")
    (String.concat "\n" body_lines ^ "\n")

let test_searxng_probe_response_is_capped () =
  check int "one look reads at most 256 KiB" 262144 R.probe_max_response_bytes

let () = run "prerequisite actions" ["user-selected plans",[
  test_case "distribution data is never shell" `Quick test_distribution_boundary;
  test_case "OS and architecture eligibility" `Quick test_platform_choices;
  test_case "explicit distro plan and failure boundary" `Quick test_linux_install_is_explicit;
  test_case "official client install selection" `Quick test_official_clients_are_explicit_and_not_ready;
  test_case "presentation workspace parser and host renderer" `Quick test_presentation_install_is_workspace_owned;
  test_case "PDF package manager selection" `Quick test_pdf_tools_reuse_selected_package_managers;
  test_case "browser tool package manager selection" `Quick
    test_browser_tools_use_the_selected_package_manager;
  test_case "browser tool actions write no file" `Quick test_browser_tool_actions_write_no_file;
  test_case "a program that answers is available at an absolute path" `Quick
    test_a_program_that_answers_is_available_at_an_absolute_path;
  test_case "a program that does not answer is failed, not missing" `Quick
    test_a_program_that_does_not_answer_is_failed_not_missing;
  test_case "a name on PATH resolves to an absolute path" `Quick
    test_a_name_on_path_resolves_to_an_absolute_path;
  test_case "a relative path is reported by its absolute path" `Quick
    test_a_relative_path_is_reported_by_its_absolute_path;
  test_case "locate finds a program without starting it" `Quick
    test_locate_finds_a_program_without_starting_it;
  test_case "locate is none for what cannot run" `Quick
    test_locate_is_none_for_what_cannot_run;
  test_case "a file that cannot be executed is missing" `Quick
    test_a_file_that_cannot_be_executed_is_missing;
  test_case "the first program that answers ends the walk" `Quick
    test_the_first_program_that_answers_ends_the_walk;
  test_case "Firefox bundle locations follow an absolute HOME" `Quick
    test_firefox_bundle_locations_follow_an_absolute_home;
  test_case "ego lite is a download page on a mac only" `Quick
    test_ego_lite_is_a_download_page_on_a_mac_only;
  test_case "the readiness JSON uses the shared status words" `Quick
    test_the_readiness_json_uses_the_shared_status_words;
  test_case "effects are not readiness" `Quick test_completion_never_means_ready;
  test_case "a builder without Rosetta offers the two ways past it" `Quick
    test_a_builder_without_rosetta_offers_the_two_ways_past_it;
  test_case "a builder without a default kernel offers to install it" `Quick
    test_a_builder_without_a_default_kernel_offers_to_install_it;
  test_case "building without Rosetta writes one line, then restarts" `Quick
    test_building_without_rosetta_writes_one_line_then_restarts];
  "hearing on a fresh machine",[
  test_case "whisper offers a package and a model" `Quick
    test_whisper_offers_a_package_and_a_model;
  test_case "a missing Homebrew is named with where it comes from" `Quick
    test_a_missing_homebrew_is_named_with_where_it_comes_from;
  test_case "a missing program that is not Homebrew is named as itself" `Quick
    test_a_missing_program_that_is_not_homebrew_is_named_as_itself;
  test_case "without a directory the model is a page" `Quick
    test_without_a_directory_the_model_is_a_page_not_a_command;
  test_case "linux gets instructions rather than a guessed package" `Quick
    test_linux_gets_instructions_rather_than_a_guessed_package;
  test_case "linux with a cache gets the same download" `Quick
    test_linux_with_a_cache_gets_the_same_download;
  test_case "hearing names the recorder, not only the transcriber" `Quick
    test_hearing_names_the_recorder_not_only_the_transcriber;
  test_case "the recorder is named where the package manager is known" `Quick
    test_the_recorder_is_named_where_the_package_manager_is_known];
  "searxng",[
  test_case "the plan follows what Docker says about the container" `Quick
    test_searxng_plan_follows_the_container;
  test_case "the settings turn JSON on and hold the key" `Quick
    test_searxng_settings_turn_json_on_and_hold_the_key;
  test_case "the settings are written once and an edit is kept" `Quick
    test_searxng_writes_the_settings_once_and_keeps_an_edit;
  test_case "a failing step stops the rest" `Quick
    test_searxng_stops_at_the_first_failing_step;
  test_case "readiness reads docker, container and endpoint" `Quick
    test_searxng_readiness_reads_docker_container_and_endpoint;
  test_case "a container that is starting is waited for, within a bound" `Quick
    test_searxng_waits_for_a_container_that_is_still_starting;
  test_case "a stopped container is started and nothing is written" `Quick
    test_searxng_starts_a_stopped_container_and_writes_nothing;
  test_case "a settings path that is not a file is refused" `Quick
    test_searxng_refuses_a_settings_path_that_is_not_a_file;
  test_case "the docker probes are bounded" `Quick
    test_searxng_docker_probes_are_bounded;
  test_case "the settings match the helper script" `Quick
    test_searxng_settings_match_the_helper_script;
  test_case "the probe response is capped" `Quick
    test_searxng_probe_response_is_capped]]
