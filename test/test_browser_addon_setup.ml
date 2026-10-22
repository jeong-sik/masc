(* What [masc browser-lane-setup] declares for the browser Lane Add-on: the
   package this build carries under .masc/packages/browser, and one
   declaration of it that the server's own reader accepts. Every case runs
   against a scratch workspace with MASC_CONFIG_DIR unset. *)
open Alcotest

module S = Masc.Browser_addon_setup
module Config = Masc.Lane_addon_config

let with_workspace ?(config = true) f =
  let dir = Filename.temp_file "browser-addon-setup" "" in
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
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" "";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Option.value previous ~default:"");
      remove dir)
    (fun () ->
       let base = Unix.realpath dir in
       if config
       then (
         Unix.mkdir (Filename.concat base ".masc") 0o700;
         Unix.mkdir (Filename.concat base ".masc/config") 0o700);
       f base)

let read path = In_channel.with_open_bin path In_channel.input_all

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let write path contents =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out contents)

let lane_directory base = Filename.concat base ".masc/config/lane-addons"

let installed base =
  match Result.bind (S.plan ~base_path:base) S.apply with
  | Ok installed -> installed
  | Error error -> failf "install refused: %s" (S.error_message error)

let embedded_files () =
  List.map
    (fun name ->
       match Embedded_browser_addon.read name with
       | Some contents -> name, contents
       | None -> failf "the embedded package lists %s without bytes" name)
    Embedded_browser_addon.file_list

(* A second copy of the package somewhere else, as an operator's own
   declaration would point at it. *)
let copy_package ~into =
  List.iter (fun (name, contents) -> write (Filename.concat into name) contents) (embedded_files ())

let declaration_text ~id ~manifest_path =
  Printf.sprintf "id = %S\nrun_id = %S\nmanifest_path = %S\n\n[binding]\nsources = []\n" id id
    manifest_path

let test_first_install_writes_the_package_and_declares_it () =
  with_workspace (fun base ->
    let result = installed base in
    let package = S.package_directory ~base_path:base in
    List.iter
      (fun (name, contents) ->
         check string ("package file " ^ name) contents (read (Filename.concat package name)))
      (embedded_files ());
    check int "every file written" (List.length (embedded_files ())) result.files_written;
    match result.declaration with
    | S.Present _ -> fail "a fresh workspace already had a declaration"
    | S.Created { path } ->
      check string "browser.toml in the Lane directory"
        (Filename.concat (lane_directory base) "browser.toml") path;
      (match Config.load_file ~path with
       | Error message -> failf "the server's reader refuses the declaration: %s" message
       | Ok declared ->
         check string "the package id" "browser" declared.package.id;
         check string "the written manifest" (Unix.realpath (Filename.concat package "lane.toml"))
           declared.manifest_path;
         check bool "enabled" true declared.enabled))

let test_a_second_install_changes_nothing () =
  with_workspace (fun base ->
    let first = installed base in
    let path =
      match first.declaration with
      | S.Created { path } -> path
      | S.Present _ -> fail "a fresh workspace already had a declaration"
    in
    let declared = read path in
    let second = installed base in
    check int "no file rewritten" 0 second.files_written;
    (match second.declaration with
     | S.Present { path = present; this_build; _ } ->
       check string "the same declaration" path present;
       check bool "it names this build's package" true this_build
     | S.Created _ -> fail "a second declaration was created");
    check string "the declaration bytes are unchanged" declared (read path))

let test_a_changed_package_file_is_rewritten_and_the_declaration_kept () =
  with_workspace (fun base ->
    let first = installed base in
    let path =
      match first.declaration with
      | S.Created { path } -> path
      | S.Present _ -> fail "a fresh workspace already had a declaration"
    in
    let declared = read path in
    let readme = Filename.concat (S.package_directory ~base_path:base) "README.md" in
    let original = read readme in
    write readme (original ^ "\nan older build's text\n");
    let second = installed base in
    check int "one file rewritten" 1 second.files_written;
    check string "the file is this build's again" original (read readme);
    check string "the declaration bytes are unchanged" declared (read path))

let test_an_existing_declaration_of_the_package_is_left_as_it_is () =
  with_workspace (fun base ->
    let elsewhere = Filename.concat base "operator-package" in
    copy_package ~into:elsewhere;
    let manifest_path = Filename.concat elsewhere "lane.toml" in
    let own = Filename.concat (lane_directory base) "browser-work.toml" in
    let text = declaration_text ~id:"browser-work" ~manifest_path in
    write own text;
    let result = installed base in
    (match result.declaration with
     | S.Created _ -> fail "a second declaration of the package was created"
     | S.Present { path; manifest_path = named; this_build; _ } ->
       check string "the operator's declaration" own path;
       check string "its own package" (Unix.realpath manifest_path) named;
       check bool "not this build's package" false this_build);
    check bool "no browser.toml" false
      (Sys.file_exists (Filename.concat (lane_directory base) "browser.toml"));
    check string "the operator's file is unchanged" text (read own))

let test_two_declarations_of_the_package_are_refused () =
  with_workspace (fun base ->
    let elsewhere = Filename.concat base "operator-package" in
    copy_package ~into:elsewhere;
    let manifest_path = Filename.concat elsewhere "lane.toml" in
    List.iter
      (fun id ->
         write (Filename.concat (lane_directory base) (id ^ ".toml")) (declaration_text ~id ~manifest_path))
      [ "browser-one"; "browser-two" ];
    match Result.bind (S.plan ~base_path:base) S.apply with
    | Ok _ -> fail "two declarations of the package were accepted"
    | Error (S.Declared_more_than_once paths) ->
      check int "both are named" 2 (List.length paths);
      check bool "nothing was written" false
        (Sys.file_exists (S.package_directory ~base_path:base))
    | Error error -> failf "refused for another reason: %s" (S.error_message error))

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path

let test_a_declaration_whose_package_was_removed_is_kept () =
  with_workspace (fun base ->
    let path =
      match (installed base).declaration with
      | S.Created { path } -> path
      | S.Present _ -> fail "a fresh workspace already had a declaration"
    in
    let declared = read path in
    remove_tree (S.package_directory ~base_path:base);
    let again = installed base in
    (match again.declaration with
     | S.Present { path = present; this_build; enabled; _ } ->
       check string "the same declaration" path present;
       check bool "it names this build's package" true this_build;
       check bool "enabled" true enabled
     | S.Created _ -> fail "a second declaration was created");
    check string "the declaration bytes are unchanged" declared (read path))

let test_an_unloadable_declaration_of_the_id_is_left_and_reported () =
  with_workspace (fun base ->
    let broken = Filename.concat (lane_directory base) "browser-checkout.toml" in
    let text =
      declaration_text ~id:"browser" ~manifest_path:(Filename.concat base "gone/lane.toml")
    in
    write broken text;
    (match Result.bind (S.plan ~base_path:base) S.apply with
     | Error (S.Declaration_unloadable { path; _ }) -> check string "the broken file" broken path
     | Ok _ -> fail "a second declaration with the same id was accepted"
     | Error error -> failf "refused for another reason: %s" (S.error_message error));
    check bool "no browser.toml" false
      (Sys.file_exists (Filename.concat (lane_directory base) "browser.toml"));
    check string "the broken file is unchanged" text (read broken))

let test_a_workspace_without_a_config_root_is_refused () =
  with_workspace ~config:false (fun base ->
    (match S.plan ~base_path:base with
     | Error (S.Config_root_missing _) -> ()
     | Ok _ -> fail "a workspace without a config root was planned"
     | Error error -> failf "refused for another reason: %s" (S.error_message error));
    check bool "no .masc was created" false (Sys.file_exists (Filename.concat base ".masc")))

let test_a_file_this_build_does_not_carry_is_removed () =
  with_workspace (fun base ->
    let (_ : S.installed) = installed base in
    let package = S.package_directory ~base_path:base in
    let leftover = Filename.concat package "skills/retired/SKILL.md" in
    write leftover "a skill an older build carried\n";
    let again = installed base in
    check int "one file removed" 1 again.files_removed;
    check bool "the file is gone" false (Sys.file_exists leftover);
    check bool "its emptied directory is gone" false
      (Sys.file_exists (Filename.dirname leftover));
    List.iter
      (fun (name, contents) ->
         check string ("package file " ^ name) contents (read (Filename.concat package name)))
      (embedded_files ()))

let test_a_relative_base_path_is_refused () =
  match S.plan ~base_path:"relative/workspace" with
  | Error (S.Base_path_not_absolute _) -> ()
  | Ok _ -> fail "a relative base path was accepted"
  | Error error -> failf "refused for another reason: %s" (S.error_message error)

let () =
  run "browser_addon_setup"
    [ ( "install"
      , [ test_case "the first install writes the package and declares it" `Quick
            test_first_install_writes_the_package_and_declares_it
        ; test_case "a second install changes nothing" `Quick test_a_second_install_changes_nothing
        ; test_case "a changed package file is rewritten and the declaration kept" `Quick
            test_a_changed_package_file_is_rewritten_and_the_declaration_kept
        ; test_case "an existing declaration of the package is left as it is" `Quick
            test_an_existing_declaration_of_the_package_is_left_as_it_is
        ; test_case "two declarations of the package are refused" `Quick
            test_two_declarations_of_the_package_are_refused
        ; test_case "a declaration whose package was removed is kept" `Quick
            test_a_declaration_whose_package_was_removed_is_kept
        ; test_case "an unloadable declaration of the id is left and reported" `Quick
            test_an_unloadable_declaration_of_the_id_is_left_and_reported
        ; test_case "a workspace without a config root is refused" `Quick
            test_a_workspace_without_a_config_root_is_refused
        ; test_case "a file this build does not carry is removed" `Quick
            test_a_file_this_build_does_not_carry_is_removed
        ; test_case "a relative base path is refused" `Quick test_a_relative_base_path_is_refused
        ] )
    ]
