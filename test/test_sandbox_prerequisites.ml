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
  let result = P.execute ~run:(fun argv -> called := argv :: !called; Error "SECRET_DIAGNOSTIC") action in
  check int "stop at first failure" 1 (List.length !called);
  check bool "failed action retained" true (match result with P.Failed {step=1;_} -> true | _ -> false);
  let serialized = Yojson.Safe.to_string (P.outcome_to_json result) in
  check bool "raw diagnostics not projected" false (String_util.contains_substring serialized "SECRET_DIAGNOSTIC")
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
      let outcome = P.execute ~run:(fun argv -> calls := argv :: !calls; Error "PRIVATE_FAILURE") action in
      check int "failed download never executes script" 1 (List.length !calls);
      let argv = List.hd !calls in
      check string "only HTTPS downloader starts" "curl" (List.hd argv);
      check bool "redirect protocol bounded to HTTPS" true (List.mem "--proto-redir" argv && List.mem "=https" argv);
      let json = Yojson.Safe.to_string (P.outcome_to_json outcome) in
      check bool "failed action stays failed" true (match outcome with P.Failed _ -> true | _ -> false);
      check bool "private error not echoed" false (String_util.contains_substring json "PRIVATE_FAILURE"))
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
  let outcome = P.execute ~run:(fun argv -> calls := argv :: !calls; Error "fixture venv failure") parser in
  check int "venv failure cannot install a package into another Python" 1 (List.length !calls);
  check bool "failed environment creation remains failed" true (match outcome with P.Failed _ -> true | _ -> false)

let () = run "prerequisite actions" ["user-selected plans",[
  test_case "distribution data is never shell" `Quick test_distribution_boundary;
  test_case "OS and architecture eligibility" `Quick test_platform_choices;
  test_case "explicit distro plan and failure boundary" `Quick test_linux_install_is_explicit;
  test_case "official client install selection" `Quick test_official_clients_are_explicit_and_not_ready;
  test_case "presentation workspace parser and host renderer" `Quick test_presentation_install_is_workspace_owned;
  test_case "PDF package manager selection" `Quick test_pdf_tools_reuse_selected_package_managers;
  test_case "effects are not readiness" `Quick test_completion_never_means_ready]]
