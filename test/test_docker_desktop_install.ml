open Alcotest
module D = Masc.Docker_desktop_install
module S = Masc.Sandbox_readiness
let payload = "official fixture disk image bytes"
let sha256 = Digestif.SHA256.(to_hex (digest_string payload))
let host = S.Macos {architecture=S.Arm64;major=26}
let with_source f =
  let directory = Filename.temp_dir "docker-install-fixture-" "" in
  let source = Filename.concat directory "source.dmg" in
  Out_channel.with_open_bin source (fun output -> output_string output payload);
  Unix.chmod source 0o600;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () -> f directory source)
let platform ?(signature=true) ?(detach=true) ?(on_mount=(fun _ -> ())) calls argv =
  calls := argv :: !calls;
  match argv with
  | ["/usr/bin/hdiutil";"attach";"-readonly";"-nobrowse";"-mountpoint";mount;image] ->
    on_mount image;
    Fs_compat.mkdir_p (Filename.concat mount "Docker.app/Contents/MacOS"); Ok ""
  | ["/usr/bin/hdiutil";"detach";mount] ->
    if detach then (Fs_compat.remove_tree (Filename.concat mount "Docker.app"); Ok "") else Error ()
  | ["/usr/bin/codesign";"--verify";"--deep";"--strict";"-R";requirement;_] ->
    check string "exact Docker trust anchor"
      "=anchor apple generic and identifier \"com.docker.docker\" and certificate leaf[subject.OU] = \"9BNSXJN65R\"" requirement;
    if signature then Ok "" else Error ()
  | ["/usr/sbin/spctl";"--assess";"--type";"execute";_] -> Ok ""
  | ["/usr/bin/plutil";"-extract";"CFBundleShortVersionString";"raw";_] -> Ok "4.90.0\n"
  | [installer] when Filename.basename installer = "install" -> Ok ""
  | _ -> fail "unexpected platform action"
let acquire calls =
  let run argv = match argv with
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--proto";"=https";url] ->
      check string "official architecture-specific checksum" "https://desktop.docker.com/mac/main/arm64/checksums.txt" url;
      Ok (sha256 ^ " *Docker.dmg\n")
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--location";"--proto";"=https";"--proto-redir";"=https";"--output";path;url] ->
      check string "official image URL" "https://desktop.docker.com/mac/main/arm64/Docker.dmg" url;
      Out_channel.with_open_bin path (fun output -> output_string output payload); Ok ""
    | _ -> platform calls argv in
  match D.acquire ~host ~run with Ok artifact -> artifact | Error error -> fail (D.error_message error)
let test_acquisition_and_owner_recheck () =
  let calls = ref [] in
  let artifact = acquire calls in
  Fun.protect ~finally:(fun () -> D.remove artifact) (fun () ->
    check bool "acquisition never installed" false (List.exists (function [path] -> Filename.basename path="install" | _ -> false) !calls);
    check string "download receipt does not attest installation" "not_attested"
      Yojson.Safe.Util.(D.to_json artifact |> member "installation" |> to_string);
    let probes = ref 0 in
    let probe_run _ = incr probes; Error S.Command_failed in
    let run = function
      | ["/usr/bin/sudo";_;"sandbox-install-docker-verified";"--source";_;"--sha256";digest;"--size";_] ->
        check string "elevated helper binds selected digest" sha256 digest;
        Ok (Yojson.Safe.to_string (D.completion_to_json {cleanup=D.Cleaned}))
      | _ -> fail "unexpected elevation argv" in
    match D.install ~executable_path:Sys.executable_name ~run ~host ~probe_run
      ~require_rootless:false ~require_userns:false artifact with
    | Error error -> fail (D.error_message error)
    | Ok result ->
      check int "post-action ordinary-user service probe ran" 1 !probes;
      check bool "install does not make failed service ready" true
        (match result.service.state with S.Probe_failed _ -> true | _ -> false);
      check bool "guest still not run" true (result.service.guest_verification=S.Not_run))
let test_official_checksum_is_required_before_mount () =
  List.iter (fun metadata ->
    let requests = ref 0 in
    let result = D.acquire ~host ~run:(fun _ -> incr requests; Ok metadata) in
    check bool "invalid or duplicate checksum refused" true (result=Error D.Invalid_checksum);
    check int "no download or mount after malformed checksum" 1 !requests)
    ["not-a-checksum *Docker.dmg\n"; sha256 ^ " *Docker.dmg\n" ^ sha256 ^ " *Docker.dmg\n"];
  let result = D.acquire ~host ~run:(function
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--proto";"=https";_] ->
      Ok (String.make 64 '0' ^ " *Docker.dmg\n")
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--location";"--proto";"=https";"--proto-redir";"=https";"--output";path;_] ->
      Out_channel.with_open_bin path (fun output -> output_string output payload); Ok ""
    | _ -> fail "digest mismatch reached mount or signature") in
  check bool "unmatched download is not interpreted" true (result=Error D.Digest_mismatch)
let test_protected_install_copy () = with_source @@ fun directory source ->
  let calls = ref [] in
  if Unix.geteuid () <> 0 then
    check bool "privileged handler rejects ordinary user without actions" true
      (D.install_privileged ~run:(fun _ -> fail "unprivileged install") ~source ~sha256
         ~size:(String.length payload) = Error D.Installer_failed);
  let on_mount image =
    check bool "mounts protected copy, not original" false (image=source);
    Out_channel.with_open_bin source (fun output -> output_string output "tampered source");
    check string "private copy retains selected bytes" payload (In_channel.with_open_bin image In_channel.input_all) in
  let result = D.For_testing.install_staged ~temp_dir:directory ~run:(platform ~on_mount calls)
    ~source ~sha256 ~size:(String.length payload) in
  check bool "protected installation completed and cleaned" true (result=Ok {D.cleanup=D.Cleaned});
  check bool "no silent license acceptance" false
    (List.exists (List.exists (String.equal "--accept-license")) !calls);
  check int "one signed vendor installer invocation" 1
    (List.length (List.filter (function [path] -> Filename.basename path="install" | _ -> false) !calls));
  check bool "changed original before elevated copy rejected" true
    (Result.is_error (D.For_testing.install_staged ~temp_dir:directory
      ~run:(fun _ -> fail "tampered input reached platform") ~source ~sha256 ~size:(String.length payload)))
let test_failure_and_cleanup_warning () = with_source @@ fun directory source ->
  let calls = ref [] in
  check bool "signature rejection prevents install" true
    (D.For_testing.install_staged ~temp_dir:directory ~run:(platform ~signature:false calls)
       ~source ~sha256 ~size:(String.length payload) = Error D.Signature_rejected);
  check bool "no installer after rejection" false
    (List.exists (function [path] -> Filename.basename path="install" | _ -> false) !calls);
  check bool "completed install keeps cleanup warning distinct" true
    (match D.For_testing.install_staged ~temp_dir:directory ~run:(platform ~detach:false calls)
       ~source ~sha256 ~size:(String.length payload) with
     | Ok {cleanup=D.Pending private_directory} -> Sys.file_exists private_directory
     | _ -> false)
let test_launch_is_explicit_and_rechecked () =
  let calls = ref [] in
  let run argv = match argv with
    | ["/usr/bin/open";"/Applications/Docker.app"] -> calls := argv :: !calls; Ok ""
    | _ -> platform calls argv in
  let probes = ref 0 in
  let result = D.launch_and_recheck ~run ~host
    ~probe_run:(fun _ -> incr probes; Error S.Command_failed)
    ~require_rootless:false ~require_userns:false () in
  check bool "launch completed but service may still start" true (Result.is_ok result);
  check int "launch requires a new service probe" 1 !probes;
  check bool "wrong platform performs no action" true
    (D.launch_and_recheck ~run:(fun _ -> fail "Linux action") ~host:(S.Linux S.X64)
      ~probe_run:(fun _ -> fail "Linux probe") ~require_rootless:false ~require_userns:false () = Error D.Unsupported_host)
let () = run "verified Docker Desktop installer" ["selected actions",[
  test_case "official acquisition and ordinary-user recheck" `Quick test_acquisition_and_owner_recheck;
  test_case "official checksum before mount" `Quick test_official_checksum_is_required_before_mount;
  test_case "root-owned copy binds vendor installation" `Quick test_protected_install_copy;
  test_case "signature failure and cleanup warning" `Quick test_failure_and_cleanup_warning;
  test_case "explicit launch and fresh service observation" `Quick test_launch_is_explicit_and_rechecked]]
