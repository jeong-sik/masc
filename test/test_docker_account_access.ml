open Alcotest
module A = Masc.Docker_account_access
module S = Masc.Sandbox_readiness
let host = S.Linux S.X64
let initial : A.For_testing.snapshot = {uid=1001;effective_uid=1001;account="selected-user";
  account_primary_gid=1001;primary_gid=1001;supplementary_gids=[1001];docker_group=Some (999,[])}
let waiting = {initial with docker_group=Some (999,["selected-user"])}
let active = {waiting with primary_gid=999}
let state snapshot = match A.For_testing.inspect ~host snapshot with
  | Ok observation -> observation.state | Error error -> fail (A.error_message error)
let test_persisted_membership_is_not_active_session () =
  check bool "fresh account needs membership" true (state initial=A.Membership_required);
  check bool "database change still needs new session" true (state waiting=A.Session_refresh_required);
  check bool "sg primary group activates ordinary account" true (state active=A.Group_active);
  check bool "supplementary membership also active" true
    (state {waiting with supplementary_gids=[1001;999]}=A.Group_active);
  check bool "root is not an ordinary account" true
    (A.For_testing.inspect ~host {active with uid=0;effective_uid=0}=Error A.Invalid_account)
let test_selected_grant_rereads_real_membership () =
  let reads = ref [initial;waiting] in
  let read () = match !reads with value::rest -> reads := rest; Ok value | [] -> fail "unexpected account reread" in
  let commands = ref [] in
  let run argv = commands := argv :: !commands; Ok () in
  match A.For_testing.grant ~host ~distribution:Masc.Sandbox_prerequisites.Debian ~read ~run with
  | Error error -> fail (A.error_message error)
  | Ok result ->
    check (list (list string)) "only current Unix account changed, no sudo docker"
      [["/usr/bin/sudo";"/usr/sbin/usermod";"-a";"-G";"docker";"--";"selected-user"]] !commands;
    check bool "grant reports required session handoff" true (result.state=A.Session_refresh_required);
    check string "no service verification inferred" "not_checked"
      Yojson.Safe.Util.(A.to_json result |> member "service_readiness" |> to_string)
let test_failed_grant_never_claims_access () =
  let run _ = Ok () in
  check bool "command success without database membership is failure" true
    (A.For_testing.grant ~host ~distribution:Masc.Sandbox_prerequisites.Ubuntu
      ~read:(fun () -> Ok initial) ~run = Error A.Grant_failed);
  check bool "existing persisted membership does not rerun sudo" true
    (Result.is_ok (A.For_testing.grant ~host ~distribution:Masc.Sandbox_prerequisites.Debian
      ~read:(fun () -> Ok waiting) ~run:(fun _ -> fail "unnecessary sudo")));
  check bool "unsupported distro never guesses a command" true
    (A.For_testing.grant ~host ~distribution:Masc.Sandbox_prerequisites.Other
      ~read:(fun () -> Ok initial) ~run:(fun _ -> fail "unsupported mutation") = Error A.Unsupported_distribution)
let test_child_requires_matching_uid_and_actual_service () =
  let never _ = fail "invalid child attempted Docker" in
  let validate snapshot expected_uid probe_run = A.For_testing.validate_session ~host ~expected_uid snapshot
    ~probe_run ~require_rootless:false ~require_userns:false in
  check bool "old process membership cannot authorize continuation" true
    (validate waiting 1001 never = Error A.Session_not_active);
  check bool "different account cannot authorize continuation" true
    (validate active 1002 never = Error A.Invalid_account);
  check bool "sudo process cannot authorize continuation" true
    (validate {active with effective_uid=0} 1001 never = Error A.Invalid_account);
  check bool "actual user service failure is retained" true
    (match validate active 1001 (fun _ -> Error S.Command_failed) with
     | Error (A.Service_unavailable _) -> true | _ -> false);
  let probe argv =
    check (list string) "ordinary-user probe without sudo" ["docker";"info";"--format";"{{json .}}"] argv;
    Ok {|{"OSType":"linux","SecurityOptions":[]}|} in
  match validate active 1001 probe with
  | Ok entry -> check bool "service proof does not imply guest proof" true (entry.guest_verification=S.Not_run)
  | Error error -> fail (A.error_message error)
let test_session_command_preserves_hostile_paths () =
  let directory = Filename.temp_dir "docker-session-quote-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
    let executable = Filename.concat directory "masc ' executable" in
    Out_channel.with_open_bin executable (fun output -> output_string output "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    Unix.chmod executable 0o700;
    let workspace = Filename.concat directory "workspace ' $(touch INJECTED) `touch INJECTED`" in
    Unix.mkdir workspace 0o700;
    let argv = match A.For_testing.session_argv ~executable_path:executable ~base_path:workspace ~port:8941 ~uid:1001 with
      | Ok argv -> argv | Error error -> fail (A.error_message error) in
    let command = match argv with ["/usr/bin/sg";"docker";"-c";command] -> command
      | _ -> fail "handoff must use supported sg command shape" in
    (* Evaluate the actual generated shell command with an inert fixture binary,
       never sg/usermod/Docker. Any injection stays inside this private fixture. *)
    let command = "cd " ^ Filename.quote directory ^ " && " ^ command in
    let child = Unix.open_process_args_in "/bin/sh" [|"/bin/sh";"-c";command|] in
    let output = In_channel.input_all child in
    check bool "fixture child completed" true (Unix.close_process_in child=Unix.WEXITED 0);
    check (list string) "all resume arguments preserved exactly"
      ["docker-session-resume";"--base-path";workspace;"--port";"8941";"--expected-uid";"1001"]
      (String.split_on_char '\n' (String.trim output));
    check bool "metacharacters did not run" false (Sys.file_exists (Filename.concat directory "INJECTED")))
let () = run "Docker ordinary-user session" ["explicit account access",[
  test_case "persisted vs active membership" `Quick test_persisted_membership_is_not_active_session;
  test_case "selected grant and database reread" `Quick test_selected_grant_rereads_real_membership;
  test_case "unconfirmed access is failure" `Quick test_failed_grant_never_claims_access;
  test_case "child UID and real service boundary" `Quick test_child_requires_matching_uid_and_actual_service;
  test_case "quoted native session continuation" `Quick test_session_command_preserves_hostile_paths]]
