open Alcotest
module A = Masc.Apple_container_install
module S = Masc.Sandbox_readiness
let payload = "fixture package bytes"
let url = "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg"
let metadata ?(name="container-1.4.1-installer-signed.pkg") ?(asset_url=url) ?(digest=Digestif.SHA256.(to_hex (digest_string payload))) () =
  `Assoc ["tag_name",`String "1.4.1";"assets",`List [`Assoc [
    "name",`String name;"browser_download_url",`String asset_url;
    "digest",`String ("sha256:" ^ digest);"size",`Int (String.length payload)]]]
let with_package f =
  let path, output = Filename.open_temp_file ~perms:0o600 "masc-installer-test-" ".pkg" in
  output_string output payload; close_out output;
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path) (fun () -> f path)
let release () = match A.release_of_json (metadata ()) with Ok release -> release | Error _ -> fail "valid fixture release"
let platform_runner ?(publisher=A.expected_publisher) ?(gatekeeper=true) calls argv =
  calls := argv :: !calls;
  match argv with
  | ["/usr/bin/env";"LC_ALL=C";"/usr/sbin/pkgutil";"--check-signature";_] -> Ok ("Certificate Chain:\n    1. " ^ publisher ^ "\n    2. Developer ID Certification Authority\n")
  | ["/usr/sbin/spctl";"--assess";"--type";"install";_] -> if gatekeeper then Ok "" else Error ()
  | ["/usr/bin/sudo";_;"sandbox-install-apple-verified";"--source";_;"--sha256";_;"--size";_] -> Ok "installer: succeeded"
  | _ -> fail "unexpected platform command"
let test_metadata () =
  List.iter (fun json -> check bool "untrusted or unsigned release refused" true
    (Result.is_error (A.release_of_json json)))
    [metadata ~name:"container-installer-unsigned.pkg" ();
     metadata ~asset_url:"https://another.example/installer.pkg" ();
     metadata ~digest:"invalid" ()]
let test_platform_and_publisher () = with_package @@ fun path ->
  let calls = ref [] in
  check bool "wrong publisher rejected even with valid hash" true
    (A.verify ~run:(platform_runner ~publisher:"Developer ID Installer: Other Company (OTHERID)" calls) ~release:(release ()) ~path = Error A.Publisher_mismatch);
  check int "wrong publisher never reaches install" 1 (List.length !calls);
  check bool "Gatekeeper rejection propagated" true
    (A.verify ~run:(platform_runner ~gatekeeper:false calls) ~release:(release ()) ~path = Error A.Signature_rejected);
  Unix.chmod path 0o644;
  let count = List.length !calls in
  check bool "public file rejected before tools" true
    (A.verify ~run:(platform_runner calls) ~release:(release ()) ~path = Error A.Invalid_file);
  check int "no platform command for unsafe file" count (List.length !calls)
let test_install_revalidates () = with_package @@ fun path ->
  let calls = ref [] in
  let run = platform_runner calls in
  let artifact = match A.verify ~run ~release:(release ()) ~path with
    | Ok artifact -> artifact | Error _ -> fail "fixture verification" in
  check bool "verified download does not attest installation" true
    (Yojson.Safe.Util.member "installation" (A.to_json artifact) = `String "not_attested");
  check bool "explicit installation invokes verified package" true (A.install ~executable_path:Sys.executable_name ~run artifact = Ok ());
  let before = List.length !calls in
  Out_channel.with_open_bin path (fun channel -> output_string channel "changed");
  check bool "changed file blocks installer" true (A.install ~executable_path:Sys.executable_name ~run artifact = Error A.Digest_mismatch);
  check int "changed file makes no further command" before (List.length !calls)
let test_acquisition () =
  let calls = ref [] in
  let download = ref None in
  let run argv = match argv with
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--proto";"=https";
       "https://api.github.com/repos/apple/container/releases/latest"] -> Ok (Yojson.Safe.to_string (metadata ()))
    | ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--location";"--proto";"=https";
       "--proto-redir";"=https";"--max-filesize";size;"--output";path;actual_url] ->
      check string "exact official asset" url actual_url;
      check string "download bounded by declared size" (string_of_int (String.length payload)) size;
      download := Some path;
      Out_channel.with_open_bin path (fun output -> output_string output payload);
      Ok ""
    | _ -> platform_runner calls argv in
  (match A.acquire ~host:(S.Linux S.Arm64) ~run with
   | Error A.Unsupported_host -> () | _ -> fail "wrong platform offered installation");
  check bool "unsupported platform does not acquire" true (!download=None);
  match A.acquire ~host:(S.Macos {architecture=S.Arm64;major=26}) ~run with
  | Error _ -> fail "fixture acquisition failed"
  | Ok artifact ->
    check bool "acquisition did not run installer" false
      (List.exists (function "/usr/bin/sudo"::_ -> true | _ -> false) !calls);
    A.remove artifact;
    check bool "private download cleaned up" false (Sys.file_exists (Option.get !download))
let test_private_install_copy () = with_package @@ fun source ->
  let copied_path = ref None in
  let installed = ref false in
  let sha256 = Digestif.SHA256.(to_hex (digest_string payload)) in
  if Unix.geteuid () <> 0 then
    check bool "internal command rejects unprivileged callers without executing"
      true (A.install_privileged ~run:(fun _ -> fail "unprivileged execution")
        ~source ~sha256 ~size:(String.length payload) = Error A.Installer_failed);
  let run argv = match argv with
    | ["/usr/bin/env";"LC_ALL=C";"/usr/sbin/pkgutil";"--check-signature";path] ->
      check bool "signature uses private copy" false (path = source);
      copied_path := Some path;
      Out_channel.with_open_bin source (fun output -> output_string output "swapped original while elevated");
      Ok ("1. " ^ A.expected_publisher)
    | ["/usr/sbin/spctl";"--assess";"--type";"install";path] ->
      check (option string) "same notarized copy" !copied_path (Some path); Ok ""
    | ["/usr/sbin/installer";"-pkg";path;"-target";"/"] ->
      check (option string) "installs same private copy" !copied_path (Some path);
      check string "original swap cannot change installed bytes" payload
        (In_channel.with_open_bin path In_channel.input_all);
      installed := true; Ok ""
    | _ -> fail "unexpected staged install command" in
  check bool "staged installation succeeds" true
    (A.For_testing.install_staged ~temp_dir:(Filename.dirname source) ~run ~source ~sha256 ~size:(String.length payload) = Ok ());
  check bool "installer reached" true !installed;
  check bool "copy cleaned" false (Sys.file_exists (Option.get !copied_path));
  installed := false;
  check bool "swap before copying blocks every platform command" true
    (Result.is_error (A.For_testing.install_staged ~temp_dir:(Filename.dirname source)
      ~run:(fun _ -> fail "changed source reached platform") ~source ~sha256 ~size:(String.length payload)));
  check bool "not installed" false !installed
let () = run "verified Apple installer" ["artifact boundary",[
  test_case "official signed asset metadata only" `Quick test_metadata;
  test_case "platform publisher and file privacy" `Quick test_platform_and_publisher;
  test_case "explicit install revalidates bytes" `Quick test_install_revalidates;
  test_case "acquisition never installs" `Quick test_acquisition;
  test_case "elevated private copy binds installed bytes" `Quick test_private_install_copy]]
