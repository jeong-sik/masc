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
    [P.Codex_cli,"codex_native_install"; P.Claude_cli,"claude_native_install"; P.Antigravity_cli,"agy_native_install"]

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
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ ->
    fail "the model step must fetch beside the path and then publish"

(* Offering a download with nowhere to write would produce a command that
   fails on a path nobody chose. The page is opened instead. *)
let test_without_a_directory_the_model_is_a_page_not_a_command () =
  let actions = whisper (mac S.Arm64 26) P.Other in
  match (find "whisper_model_page" actions).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ ->
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
          | P.Run_commands _ | P.Install_official_cli _ ->
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
      | P.Open_official_installer _ | P.Install_official_cli _ ->
        fail "a known package manager can name the package")
    [ P.Debian; P.Ubuntu ];
  match (find "sox_project_page" (whisper (S.Linux S.X64) P.Other)).action_effect with
  | P.Open_official_installer _ -> ()
  | P.Run_commands _ | P.Install_official_cli _ ->
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
  | P.Open_official_installer _ | P.Install_official_cli _ ->
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
  | P.Run_commands _ | P.Open_official_installer _ | P.Install_official_cli _ ->
    fail "linux with a cache directory must get the download too"

let () = run "prerequisite actions" ["user-selected plans",[
  test_case "distribution data is never shell" `Quick test_distribution_boundary;
  test_case "OS and architecture eligibility" `Quick test_platform_choices;
  test_case "explicit distro plan and failure boundary" `Quick test_linux_install_is_explicit;
  test_case "official client install selection" `Quick test_official_clients_are_explicit_and_not_ready;
  test_case "PDF package manager selection" `Quick test_pdf_tools_reuse_selected_package_managers;
  test_case "effects are not readiness" `Quick test_completion_never_means_ready];
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
