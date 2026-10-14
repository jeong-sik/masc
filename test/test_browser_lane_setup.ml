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
let with_fixture_named name f =
  with_directory (fun root ->
    let base_path = Filename.concat root name in
    Unix.mkdir base_path 0o700;
    let manifests = Filename.concat root "native manifests" in
    let source = Filename.concat root "scratch-host" in
    write ~mode:0o755 source echo_host;
    f { root; base_path; manifests; source })

let with_fixture f = with_fixture_named "browser host ' workspace" f

let request ?token_file ?(host_name = S.Host_name.default) fixture =
  { S.base_path = fixture.base_path
  ; binary = Some fixture.source
  ; token_file
  ; extension = Some { S.manifest_dir = fixture.manifests; host_name }
  }

(* The BiDi route: the host and the launcher, no extension and no manifest. *)
let host_only fixture = { (request fixture) with S.extension = None }

(* What the extension route wrote, for a test that asked for it. *)
let extension (installed : S.installed) =
  match installed.S.extension with
  | Some extension -> extension
  | None -> Alcotest.fail "the extension route was asked for and wrote none"

let install_ok request =
  match S.install request with
  | Ok installed -> installed
  | Error error -> fail (S.error_message error)

let expect_error label expected = function
  | Ok _ -> fail (label ^ ": expected a refusal")
  | Error error -> check bool (label ^ " (got: " ^ S.error_message error ^ ")") true (expected error)

let exists path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error _ -> false

let lane_directory fixture =
  List.fold_left Filename.concat fixture.base_path [ ".masc"; "browser-lane" ]

(* What is left in the workspace and the manifest directory after a refused
   install: nothing that reads as an installed lane, and no manifest. *)
let nothing_installed label fixture =
  let observed = L.observe ~base_path:fixture.base_path ~server:L.Not_serving in
  check bool (label ^ ": the lane reads as not installed") true
    (observed.L.launcher = L.Not_installed);
  check bool (label ^ ": no launcher") false
    (exists (L.launcher_path ~base_path:fixture.base_path));
  check bool (label ^ ": no declaration") false
    (exists (L.declaration_path ~base_path:fixture.base_path))

let json_member name json = Yojson.Safe.Util.member name json
let json_string name json = Yojson.Safe.Util.to_string (json_member name json)

let installs_paths_that_outlive_the_source_and_keeps_the_token fixture =
    let first = install_ok (request fixture) in
    let token = read first.S.token in
    check int "token is private" 0o600 (Unix.stat first.S.token).Unix.st_perm;
    check int "token is 48 hex digits and a newline" 49 (String.length token);
    ignore (install_ok (request fixture));
    check string "a second install keeps the token" token (read first.S.token);
    Sys.remove fixture.source;
    check bool "the copied host is the installed one" true
      (Sys.file_exists first.S.host && (Unix.stat first.S.host).Unix.st_perm = 0o755);
    let manifest = Yojson.Safe.from_string (read (extension first).S.native_manifest) in
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
    let manifest_arg = (extension first).S.native_manifest in
    let channel =
      Unix.open_process_args_in first.S.launcher [| first.S.launcher; manifest_arg; extension_id |]
    in
    let received = In_channel.input_all channel in
    ignore (Unix.close_process_in channel);
    (* One argument per line, compared as one text: a workspace name may hold a
       newline of its own. *)
    check string "what the host receives"
      (String.concat "\n"
         [ "--base-path"; fixture.base_path; "--token-file"; first.S.token; manifest_arg
         ; extension_id; "" ])
      received

let test_installs_paths_that_outlive_the_source_and_keeps_the_token () =
  with_fixture installs_paths_that_outlive_the_source_and_keeps_the_token

(* Every character a shell treats specially, in the workspace's own name. *)
let test_a_hostile_workspace_name_reaches_the_host_exactly () =
  with_fixture_named "w $HOME `id` \"q\" \\ back\nnew\xc3\xa9 ' end"
    installs_paths_that_outlive_the_source_and_keeps_the_token

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
      (Filename.concat (extension installed).S.directory "manifest.json")
      (extension installed).S.load;
    let extension_manifest = Yojson.Safe.from_string (read (extension installed).S.load) in
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
      (Sys.file_exists (Filename.concat (extension installed).S.directory "background.js"));
    check int "extension files are not executable" 0o644
      (Unix.stat (extension installed).S.load).Unix.st_perm)

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
      (extension installed).S.native_manifest;
    let manifest = Yojson.Safe.from_string (read (extension installed).S.native_manifest) in
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
    (* There is no unsetenv in the standard library; PATH is always set where
       this runs, so it is put back as it was. *)
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
  check string "macOS"
    "/Users/fixture/Library/Application Support/Mozilla/NativeMessagingHosts"
    (S.default_manifest_directory ~home S.Macos);
  check string "Linux" "/Users/fixture/.mozilla/native-messaging-hosts"
    (S.default_manifest_directory ~home S.Linux)

(* What a lane token is: the one rule the host, the server and this command
   share. *)
let test_a_lane_token_is_sixteen_visible_characters_around_which_space_is_trimmed () =
  let module T = Browser_lane.Lane_token in
  let accepted text =
    match T.of_text text with
    | Ok token -> T.to_string token
    | Error refusal -> fail (Printf.sprintf "%S refused: %s" text (T.refusal_message refusal))
  in
  check string "exactly the minimum" "0123456789abcdef" (accepted "0123456789abcdef");
  check string "surrounding whitespace is not part of it" "0123456789abcdef"
    (accepted "  0123456789abcdef\r\n");
  check string "visible punctuation is allowed" "a-b_c.d~e!f#g$h%i" (accepted "a-b_c.d~e!f#g$h%i");
  let refused expected text =
    match T.of_text text with
    | Ok _ -> fail (Printf.sprintf "%S must be refused" text)
    | Error refusal -> check bool (Printf.sprintf "%S" text) true (refusal = expected)
  in
  refused T.Too_short "";
  refused T.Too_short "\n";
  refused T.Too_short "0123456789abcde";
  refused T.Too_short "  0123456789abcde  ";
  refused T.Not_printable "0123456789 abcdef";
  refused T.Not_printable "0123456789\tabcdef";
  refused T.Not_printable "0123456789abcdef\x00";
  refused T.Not_printable "0123456789abcd\xc3\xa9f"

(* The installer refuses what the host would refuse, before it writes anything:
   a lane with such a token fails closed with no word from the installer. *)
let test_a_token_the_host_would_refuse_is_refused_before_anything_is_written () =
  with_fixture (fun fixture ->
    List.iter (fun (label, text) ->
      let provisioned = Filename.concat fixture.root "short-token" in
      write provisioned text;
      expect_error label (function S.Token_file_unusable _ -> true | _ -> false)
        (S.install (request ~token_file:provisioned fixture));
      check bool (label ^ ": no lane directory") false (exists (lane_directory fixture)))
      [ "a token that is too short", "tok-abc123\n"
      ; "a token that is only a newline", "\n"
      ; "a token with a space inside", "tok abc 0123456789 xyz\n" ])

(* The lane token is whole from the moment it exists. A reader that polls the
   file while installs race for it must never see it empty or short, which is
   what an install that created the file and then wrote it would show; and no
   install may be refused for that. Real processes, because the interleaving
   that matters is between the system calls of different processes. Each round
   is a fresh workspace, since one round may not interleave. *)
let racing_rounds = 25
let racing_installs = 8
let whole_token_size = 49

let test_the_lane_token_is_never_seen_before_it_is_whole_while_installs_race () =
  with_fixture (fun fixture ->
    let partial_sightings = ref 0 in
    for round = 1 to racing_rounds do
      let base_path = Filename.concat fixture.root (Printf.sprintf "race-%d" round) in
      Unix.mkdir base_path 0o700;
      let lane = List.fold_left Filename.concat base_path [ ".masc"; "browser-lane" ] in
      let canonical = Filename.concat lane "token" in
      (* The children wait on a pipe and start together when the parent closes
         it, so the parent is already watching when the first of them reaches
         the token. Forking eight copies of this process takes longer than an
         install does, so without the wait the token would exist before the
         parent looked. *)
      let gate_read, gate_write = Unix.pipe () in
      let children =
        List.init racing_installs (fun _ ->
          match Unix.fork () with
          | 0 ->
            Unix.close gate_write;
            ignore (Unix.read gate_read (Bytes.create 1) 0 1);
            let code =
              match S.install { (request fixture) with S.base_path } with
              | Ok _ -> 0
              | Error error ->
                prerr_endline (S.error_message error);
                1
            in
            Unix._exit code
          | pid -> pid)
      in
      Unix.close gate_read;
      Unix.close gate_write;
      let refused = ref 0 in
      let pending = ref children in
      let polls_between_waits = 64 in
      while !pending <> [] do
        for _ = 1 to polls_between_waits do
          match Unix.stat canonical with
          | { Unix.st_size; _ } when st_size <> whole_token_size -> incr partial_sightings
          | _ -> ()
          | exception Unix.Unix_error _ -> ()
        done;
        pending :=
          List.filter
            (fun pid ->
               match Unix.waitpid [ Unix.WNOHANG ] pid with
               | 0, _ -> true
               | _, Unix.WEXITED 0 -> false
               | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) ->
                 incr refused;
                 false)
            !pending
      done;
      check int (Printf.sprintf "round %d: installs that were refused" round) 0 !refused;
      check int (Printf.sprintf "round %d: one whole token" round) whole_token_size
        (String.length (read canonical));
      let leftovers =
        List.filter
          (fun entry ->
             String.starts_with ~prefix:".token-" entry
             || String.starts_with ~prefix:".install-" entry)
          (Array.to_list (Sys.readdir lane))
      in
      check (list string) (Printf.sprintf "round %d: no temporary file is left" round) [] leftovers
    done;
    check int "times the token was seen empty or short" 0 !partial_sightings)

(* A manifest directory that is a file, or one nobody may write into, stops the
   install before it writes anything, so the lane never reads as installed. *)
let test_a_manifest_directory_that_cannot_be_used_leaves_nothing_installed () =
  with_fixture (fun fixture ->
    write fixture.manifests "not a directory";
    expect_error "a manifest directory that is a file" (function S.Io _ -> true | _ -> false)
      (S.install (request fixture));
    nothing_installed "a file as manifest directory" fixture;
    check bool "no extension was written" false
      (exists (Filename.concat (lane_directory fixture) "extension/manifest.json")));
  if Unix.geteuid () <> 0
  then
    with_fixture (fun fixture ->
      Unix.mkdir fixture.manifests 0o555;
      Fun.protect ~finally:(fun () -> Unix.chmod fixture.manifests 0o755) (fun () ->
        expect_error "a read-only manifest directory" (function S.Io _ -> true | _ -> false)
          (S.install (request fixture));
        nothing_installed "a read-only manifest directory" fixture))

let test_an_extension_directory_that_is_a_file_leaves_nothing_installed () =
  with_fixture (fun fixture ->
    Unix.mkdir (Filename.concat fixture.base_path ".masc") 0o700;
    Unix.mkdir (lane_directory fixture) 0o700;
    write (Filename.concat (lane_directory fixture) "extension") "in the way";
    expect_error "an extension path that is a file" (function S.Io _ -> true | _ -> false)
      (S.install (request fixture));
    nothing_installed "a file as extension directory" fixture;
    check bool "no manifest was registered" false
      (exists (Filename.concat fixture.manifests "masc_browser_host.json")))

(* A manifest that cannot be put in place passes every check made up front
   (its directory is a writable directory) and fails after the launcher is
   written. The lane must then not read as installed: [launch.json] is written
   last, so the launcher stands without a declaration and is reported as such. *)
let test_an_install_that_stops_after_the_launcher_does_not_read_as_installed () =
  with_fixture (fun fixture ->
    Unix.mkdir fixture.manifests 0o700;
    Unix.mkdir (Filename.concat fixture.manifests "masc_browser_host.json") 0o700;
    expect_error "a manifest path that is a directory" (function S.Io _ -> true | _ -> false)
      (S.install (request fixture));
    let observed = L.observe ~base_path:fixture.base_path ~server:L.Not_serving in
    check bool "the launcher is there" true (exists (L.launcher_path ~base_path:fixture.base_path));
    check bool "its declaration is not" false (exists (L.declaration_path ~base_path:fixture.base_path));
    check bool "so the lane is reported as undeclared" true (observed.L.launcher = L.Undeclared);
    check bool "and not as following the workspace" false
      (observed.L.launcher = L.Follows_workspace))

(* A provisioned token may be named relative to the workspace, and may be the
   workspace's own token file. *)
let test_a_token_file_may_be_relative_or_the_canonical_file_itself () =
  with_fixture (fun fixture ->
    write (Filename.concat fixture.base_path "provisioned") "relative-provisioned-token\n";
    ignore (install_ok (request ~token_file:"provisioned" fixture));
    let canonical = Filename.concat (lane_directory fixture) "token" in
    check string "the relative file's token" "relative-provisioned-token\n" (read canonical);
    let again = install_ok (request ~token_file:canonical fixture) in
    check string "the canonical file named explicitly" canonical again.S.token;
    check string "and left as it was" "relative-provisioned-token\n" (read canonical))

(* --- the BiDi route installs the host alone ------------------------------ *)

let test_the_bidi_route_installs_the_host_and_no_extension () =
  with_fixture (fun fixture ->
    let installed = install_ok (host_only fixture) in
    check bool "no extension is reported" true (Option.is_none installed.S.extension);
    check bool "no extension files" false (exists (Filename.concat (lane_directory fixture) "extension"));
    check bool "no manifest directory was made" false (exists fixture.manifests);
    check int "the host is the installed one" 0o755 (Unix.stat installed.S.host).Unix.st_perm;
    check int "the token is private" 0o600 (Unix.stat installed.S.token).Unix.st_perm;
    let observed = L.observe ~base_path:fixture.base_path ~server:L.Not_serving in
    check bool "the lane reads as installed" true (observed.L.launcher = L.Follows_workspace);
    let channel = Unix.open_process_args_in installed.S.launcher [| installed.S.launcher |] in
    let received = In_channel.input_all channel in
    ignore (Unix.close_process_in channel);
    check string "the host is given the workspace and the token"
      (String.concat "\n" [ "--base-path"; fixture.base_path; "--token-file"; installed.S.token; "" ])
      received)

(* A manifest directory is the extension route's. A path that cannot be one
   stops that route and not the other. *)
let test_a_manifest_directory_that_is_a_file_does_not_stop_the_bidi_route () =
  with_fixture (fun fixture ->
    write fixture.manifests "not a directory";
    ignore (install_ok (host_only fixture));
    check bool "the lane is installed" true
      ((L.observe ~base_path:fixture.base_path ~server:L.Not_serving).L.launcher
       = L.Follows_workspace);
    check string "the file there was left alone" "not a directory" (read fixture.manifests))

let test_the_bidi_route_after_the_extension_route_leaves_what_the_extension_wrote () =
  with_fixture (fun fixture ->
    let first = install_ok (request fixture) in
    let manifest = (extension first).S.native_manifest and load = (extension first).S.load in
    let manifest_text = read manifest and load_text = read load in
    let token = read first.S.token in
    let again = install_ok (host_only fixture) in
    check bool "it writes no extension this time" true (Option.is_none again.S.extension);
    check string "the manifest is as it was" manifest_text (read manifest);
    check string "the extension is as it was" load_text (read load);
    check string "the token is the one that was there" token (read again.S.token))

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
        ; test_case "a hostile workspace name reaches the host exactly" `Quick
            test_a_hostile_workspace_name_reaches_the_host_exactly
        ; test_case "a lane token is sixteen visible characters" `Quick
            test_a_lane_token_is_sixteen_visible_characters_around_which_space_is_trimmed
        ; test_case "a token the host would refuse is refused first" `Quick
            test_a_token_the_host_would_refuse_is_refused_before_anything_is_written
        ; test_case "the lane token is never seen before it is whole" `Quick
            test_the_lane_token_is_never_seen_before_it_is_whole_while_installs_race
        ; test_case "an unusable manifest directory leaves nothing installed" `Quick
            test_a_manifest_directory_that_cannot_be_used_leaves_nothing_installed
        ; test_case "an extension path that is a file leaves nothing installed" `Quick
            test_an_extension_directory_that_is_a_file_leaves_nothing_installed
        ; test_case "an install that stops after the launcher is not installed" `Quick
            test_an_install_that_stops_after_the_launcher_does_not_read_as_installed
        ; test_case "a token file may be relative or the canonical file" `Quick
            test_a_token_file_may_be_relative_or_the_canonical_file_itself
        ] )
    ; ( "the BiDi route"
      , [ test_case "installs the host and no extension" `Quick
            test_the_bidi_route_installs_the_host_and_no_extension
        ; test_case "a manifest directory that is a file does not stop it" `Quick
            test_a_manifest_directory_that_is_a_file_does_not_stop_the_bidi_route
        ; test_case "leaves what the extension route wrote" `Quick
            test_the_bidi_route_after_the_extension_route_leaves_what_the_extension_wrote
        ] )
    ]
