(* The browser lane installation: what [masc browser-lane-setup --mode
   extension] writes, and that the reader of those files accepts it. Every case
   runs against a scratch workspace and a scratch manifest directory. *)
open Alcotest

module S = Masc.Browser_lane_setup
module L = Masc.Browser_lane_launcher

let extension_id = "browser-lane@masc.local"

let with_directory f =
  let dir = Filename.temp_file "lane-setup" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    | _ -> (try Sys.remove path with Sys_error _ -> ())
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> f (Unix.realpath dir))

let write ?(mode = 0o644) path contents =
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  Unix.chmod path mode

let read path = In_channel.with_open_bin path In_channel.input_all

(* A host that prints the arguments it was given, one per line, so a test can
   see exactly what the launcher passes to it. *)
let echo_host = "#!/bin/sh\nprintf '%s\\n' \"$@\"\n"

type fixture =
  { root : string
  ; base_path : string
  ; manifests : string
  ; source : string
  }

(* The workspace name holds a space and a quote: both reach a shell script. *)
let with_fixture f =
  with_directory (fun root ->
    let base_path = Filename.concat root "browser host ' workspace" in
    Unix.mkdir base_path 0o700;
    let manifests = Filename.concat root "native manifests" in
    let source = Filename.concat root "scratch-host" in
    write ~mode:0o755 source echo_host;
    f { root; base_path; manifests; source })

let request ?token_file ?(host_name = S.Host_name.default) fixture =
  { S.base_path = fixture.base_path
  ; binary = Some fixture.source
  ; token_file
  ; manifest_dir = fixture.manifests
  ; host_name
  }

let install_ok request =
  match S.install request with
  | Ok installed -> installed
  | Error error -> fail (S.error_message error)

let expect_error label expected = function
  | Ok _ -> fail (label ^ ": expected a refusal")
  | Error error -> check bool label true (expected error)

let json_member name json = Yojson.Safe.Util.member name json
let json_string name json = Yojson.Safe.Util.to_string (json_member name json)

let test_installs_paths_that_outlive_the_source_and_keeps_the_token () =
  with_fixture (fun fixture ->
    let first = install_ok (request fixture) in
    let token = read first.S.token in
    check int "token is private" 0o600 (Unix.stat first.S.token).Unix.st_perm;
    check int "token is 48 hex digits and a newline" 49 (String.length token);
    ignore (install_ok (request fixture));
    check string "a second install keeps the token" token (read first.S.token);
    Sys.remove fixture.source;
    check bool "the copied host is the installed one" true
      (Sys.file_exists first.S.host && (Unix.stat first.S.host).Unix.st_perm = 0o755);
    let manifest = Yojson.Safe.from_string (read first.S.manifest) in
    check string "manifest points at the launcher" first.S.launcher (json_string "path" manifest);
    check string "manifest name" "masc_browser_host" (json_string "name" manifest);
    check string "stdio" "stdio" (json_string "type" manifest);
    check (list string) "only the MASC extension may start it" [ extension_id ]
      (List.map Yojson.Safe.Util.to_string
         (Yojson.Safe.Util.to_list (json_member "allowed_extensions" manifest)));
    check bool "the token value is not written into the launcher" false
      (String_util.contains_substring (read first.S.launcher) (String.trim token));
    (* Firefox appends the manifest path and the extension id; the launcher
       must hand them to the host after its own arguments. *)
    let manifest_arg = first.S.manifest in
    let channel =
      Unix.open_process_args_in first.S.launcher [| first.S.launcher; manifest_arg; extension_id |]
    in
    let lines =
      let rec read_all acc =
        match In_channel.input_line channel with
        | Some line -> read_all (line :: acc)
        | None -> List.rev acc
      in
      read_all []
    in
    ignore (Unix.close_process_in channel);
    check (list string) "what the host receives"
      [ "--base-path"; fixture.base_path; "--token-file"; first.S.token; manifest_arg; extension_id ]
      lines)

(* The launcher is read back by the code that diagnoses it, so the writer and
   the reader are tested against each other and not against a copy of the
   format. *)
let test_the_reader_accepts_what_was_written () =
  with_fixture (fun fixture ->
    let before = L.observe ~base_path:fixture.base_path ~server:L.Not_serving in
    check bool "nothing is installed yet" true (before.L.launcher = L.Not_installed);
    ignore (install_ok (request fixture));
    let after = L.observe ~base_path:fixture.base_path ~server:L.Not_serving in
    check bool "the declaration matches the launcher" true
      (after.L.launcher = L.Follows_workspace))

let test_extension_files_are_written_for_the_id_the_manifest_grants () =
  with_fixture (fun fixture ->
    let installed = install_ok (request fixture) in
    check string "the file to choose in about:debugging"
      (Filename.concat installed.S.extension_directory "manifest.json")
      installed.S.extension_manifest;
    let extension_manifest = Yojson.Safe.from_string (read installed.S.extension_manifest) in
    let id =
      Yojson.Safe.Util.(
        extension_manifest
        |> member "browser_specific_settings"
        |> member "gecko"
        |> member "id"
        |> to_string)
    in
    check string "the id the host binary accepts" extension_id id;
    check bool "the background script is written" true
      (Sys.file_exists (Filename.concat installed.S.extension_directory "background.js"));
    check int "extension files are not executable" 0o644
      (Unix.stat installed.S.extension_manifest).Unix.st_perm)

let test_host_names_are_segments_of_lowercase_words () =
  List.iter
    (fun name ->
       match S.Host_name.of_string name with
       | Ok accepted -> check string "round trip" name (S.Host_name.to_string accepted)
       | Error message -> fail (name ^ ": " ^ message))
    [ "masc_browser_host"; "masc_public_reddit_a1"; "a.b"; "x" ];
  List.iter
    (fun name ->
       match S.Host_name.of_string name with
       | Ok _ -> fail (Printf.sprintf "%S names a path or shell data and must be refused" name)
       | Error _ -> ())
    [ ""; "../owned"; "a-b"; ".a"; "a."; "a..b"; "A"; "a b"; "a/b" ]

let test_an_isolated_host_name_names_its_own_manifest () =
  with_fixture (fun fixture ->
    let host_name =
      match S.Host_name.of_string "masc_public_reddit_a1" with
      | Ok name -> name
      | Error message -> fail message
    in
    let installed = install_ok (request ~host_name fixture) in
    check string "manifest file"
      (Filename.concat fixture.manifests "masc_public_reddit_a1.json")
      installed.S.manifest;
    let manifest = Yojson.Safe.from_string (read installed.S.manifest) in
    check string "name" "masc_public_reddit_a1" (json_string "name" manifest);
    check string "launcher" "launch" (Filename.basename (json_string "path" manifest)))

let test_a_provisioned_token_must_exist_and_match () =
  with_fixture (fun fixture ->
    let provisioned = Filename.concat fixture.root "provisioned-token" in
    let canonical =
      List.fold_left Filename.concat fixture.base_path [ ".masc"; "browser-lane"; "token" ]
    in
    expect_error "a token file that is absent" (function S.Token_file_unusable _ -> true | _ -> false)
      (S.install (request ~token_file:provisioned fixture));
    check bool "nothing was created for it" false (Sys.file_exists canonical);
    write provisioned "provisioned-browser-lane-test-token\n";
    ignore (install_ok (request ~token_file:provisioned fixture));
    check string "the provisioned token becomes the canonical one"
      "provisioned-browser-lane-test-token\n" (read canonical);
    write provisioned "different-browser-lane-test-token\n";
    expect_error "a token that is not the workspace's"
      (function S.Token_file_differs _ -> true | _ -> false)
      (S.install (request ~token_file:provisioned fixture));
    check string "the canonical token is left alone"
      "provisioned-browser-lane-test-token\n" (read canonical))

let test_an_empty_workspace_token_is_refused_and_left_alone () =
  with_fixture (fun fixture ->
    let lane = Filename.concat (Filename.concat fixture.base_path ".masc") "browser-lane" in
    Unix.mkdir (Filename.concat fixture.base_path ".masc") 0o700;
    Unix.mkdir lane 0o700;
    let canonical = Filename.concat lane "token" in
    write ~mode:0o600 canonical "";
    expect_error "an empty token" (function S.Lane_token_unusable _ -> true | _ -> false)
      (S.install (request fixture));
    check string "it was not replaced" "" (read canonical))

let test_a_host_that_cannot_run_writes_nothing () =
  with_fixture (fun fixture ->
    let lane = List.fold_left Filename.concat fixture.base_path [ ".masc"; "browser-lane" ] in
    expect_error "a binary that is not there"
      (function S.Host_binary_not_executable _ -> true | _ -> false)
      (S.install
         { (request fixture) with S.binary = Some (Filename.concat fixture.root "absent-host") });
    let plain = Filename.concat fixture.root "plain-file" in
    write ~mode:0o644 plain "not a program";
    expect_error "a file without the execute bit"
      (function S.Host_binary_not_executable _ -> true | _ -> false)
      (S.install { (request fixture) with S.binary = Some plain });
    check bool "no lane directory appeared" false (Sys.file_exists lane);
    check bool "no manifest appeared" false (Sys.file_exists fixture.manifests))

let test_a_relative_workspace_is_refused () =
  with_fixture (fun fixture ->
    expect_error "a relative workspace"
      (function S.Base_path_not_absolute _ -> true | _ -> false)
      (S.install { (request fixture) with S.base_path = "relative/workspace" }))

(* With no --binary the host is the one on PATH when none sits beside this
   executable, and nothing is guessed when there is none. *)
let test_the_host_is_found_on_path_or_not_at_all () =
  with_fixture (fun fixture ->
    let bin = Filename.concat fixture.root "bin" in
    Unix.mkdir bin 0o700;
    write ~mode:0o755 (Filename.concat bin "masc-browser-host") echo_host;
    let previous = Sys.getenv_opt "PATH" in
    let restore () = Unix.putenv "PATH" (Option.value previous ~default:"") in
    Fun.protect ~finally:restore (fun () ->
      Unix.putenv "PATH" bin;
      let installed = install_ok { (request fixture) with S.binary = None } in
      check string "copied from PATH" echo_host (read installed.S.host);
      Unix.putenv "PATH" (Filename.concat fixture.root "empty");
      expect_error "no host anywhere" (function S.Host_binary_not_found -> true | _ -> false)
        (S.install { (request fixture) with S.binary = None })))

let test_firefox_manifest_directory_follows_the_host_os () =
  let home = "/Users/fixture" in
  check (option string) "macOS"
    (Some "/Users/fixture/Library/Application Support/Mozilla/NativeMessagingHosts")
    (S.default_manifest_directory ~home
       (Masc.Sandbox_readiness.Macos { architecture = Masc.Sandbox_readiness.Arm64; major = 26 }));
  check (option string) "Linux" (Some "/Users/fixture/.mozilla/native-messaging-hosts")
    (S.default_manifest_directory ~home (Masc.Sandbox_readiness.Linux Masc.Sandbox_readiness.X64));
  check (option string) "anything else" None
    (S.default_manifest_directory ~home Masc.Sandbox_readiness.Unsupported)

let () =
  run "browser lane setup"
    [ ( "installation"
      , [ test_case "paths outlive the source and the token is kept" `Quick
            test_installs_paths_that_outlive_the_source_and_keeps_the_token
        ; test_case "the reader accepts what was written" `Quick
            test_the_reader_accepts_what_was_written
        ; test_case "extension files carry the id the host accepts" `Quick
            test_extension_files_are_written_for_the_id_the_manifest_grants
        ; test_case "host names are lowercase segments" `Quick
            test_host_names_are_segments_of_lowercase_words
        ; test_case "an isolated host name names its own manifest" `Quick
            test_an_isolated_host_name_names_its_own_manifest
        ; test_case "a provisioned token must exist and match" `Quick
            test_a_provisioned_token_must_exist_and_match
        ; test_case "an empty workspace token is refused and left alone" `Quick
            test_an_empty_workspace_token_is_refused_and_left_alone
        ; test_case "a host that cannot run writes nothing" `Quick
            test_a_host_that_cannot_run_writes_nothing
        ; test_case "a relative workspace is refused" `Quick
            test_a_relative_workspace_is_refused
        ; test_case "the host is found on PATH or not at all" `Quick
            test_the_host_is_found_on_path_or_not_at_all
        ; test_case "Firefox's manifest directory follows the host OS" `Quick
            test_firefox_manifest_directory_follows_the_host_os
        ] )
    ]
