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
let () = run "prerequisite actions" ["user-selected plans",[
  test_case "distribution data is never shell" `Quick test_distribution_boundary;
  test_case "OS and architecture eligibility" `Quick test_platform_choices;
  test_case "explicit distro plan and failure boundary" `Quick test_linux_install_is_explicit;
  test_case "effects are not readiness" `Quick test_completion_never_means_ready]]
