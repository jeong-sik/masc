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

(* An install action for these never writes runtime.toml: naming the executable
   there needs the path the install leaves behind. *)
let test_browser_tool_actions_write_no_file () =
  List.iter (fun dependency ->
    List.iter (fun host ->
      List.iter (fun (action : P.action) ->
        check (option string) "no file is left behind" None action.writes)
        (P.catalog ~host ~distribution:P.Ubuntu dependency))
      [mac S.Arm64 26; S.Linux S.X64])
    [P.Geckodriver; P.Firefox]

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
  check (list string) "geckodriver is a bare name" ["geckodriver"] (B.candidates B.Geckodriver)

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
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
    fail "the model step must fetch beside the path and then publish"

(* Offering a download with nowhere to write would produce a command that
   fails on a path nobody chose. The page is opened instead. *)
let test_without_a_directory_the_model_is_a_page_not_a_command () =
  let actions = whisper (mac S.Arm64 26) P.Other in
  match (find "whisper_model_page" actions).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
          | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
      | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
        fail "a known package manager can name the package")
    [ P.Debian; P.Ubuntu ];
  match (find "sox_project_page" (whisper (S.Linux S.X64) P.Other)).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
  | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
   | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
   | P.Open_official_installer _ | P.Install_official_cli _ | P.Build_without_rosetta _ ->
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
    test_the_recorder_is_named_where_the_package_manager_is_known]]
