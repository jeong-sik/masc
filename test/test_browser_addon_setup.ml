(* What [masc browser-lane-setup] declares for the browser Lane Add-ons: for
   each browser source it is given, the package this build carries for that
   source under .masc/packages/browser-<source>, and one declaration of it
   that the server's own reader accepts. Every case runs against a scratch
   workspace with MASC_CONFIG_DIR unset. *)
open Alcotest

module S = Masc.Browser_addon_setup
module Config = Masc.Lane_addon_config
module Types = Masc.Lane_addon_types
module B = Browser_lane.Backend

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
       (* A config root is a directory holding runtime.toml, prompts/ or
          keepers/ (Config_dir_resolver); an empty one is not a workspace. *)
       if config
       then (
         Unix.mkdir (Filename.concat base ".masc") 0o700;
         Unix.mkdir (Filename.concat base ".masc/config") 0o700;
         Out_channel.with_open_bin (Filename.concat base ".masc/config/runtime.toml")
           (fun out -> output_string out "# scratch workspace\n"));
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

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path

let manifest_name = "lane.toml"
let lane_directory base = Filename.concat base ".masc/config/lane-addons"
let packages_directory base = Filename.concat base ".masc/packages"

(* The folder of each source's package in addons/browser, as this test knows
   it independently of setup; setup names the package [browser-<folder>]. *)
let folder = function
  | B.Automation -> "automation"
  | B.Stagehand -> "stagehand"
  | B.Owned_firefox -> "firefox"
  | B.Ego -> "ego"
  | B.External_host -> "external"

let declaration_path base backend =
  Filename.concat (lane_directory base) (S.package_name backend ^ ".toml")

(* The files the binary carries for [backend]'s package, named relative to
   that package. *)
let embedded_files backend =
  let prefix = folder backend ^ "/" in
  List.filter_map
    (fun carried ->
       if String.starts_with ~prefix carried
       then (
         let name =
           String.sub carried (String.length prefix) (String.length carried - String.length prefix)
         in
         match Embedded_browser_addon.read carried with
         | Some contents -> Some (name, contents)
         | None -> failf "the embedded package lists %s without bytes" carried)
       else None)
    Embedded_browser_addon.file_list

let serves backend (declared : Config.declaration) =
  match declared.package.Types.worker_service with
  | Types.Browser_service served -> served = backend
  | Types.Mcp_tools -> false

let wire (installed : S.installed list) =
  List.map (fun (one : S.installed) -> B.to_wire one.backend) installed

(* Plan, then apply: a refusal of either, with what apply completed first. *)
let install ~sources base =
  match S.plan ~base_path:base ~sources with
  | Error error -> [], Some error
  | Ok plan -> let { S.installed; refusal } = S.apply plan in installed, refusal

let installed ?(sources = B.all) base =
  match install ~sources base with
  | installed, None -> installed
  | _, Some error -> failf "install refused: %s" (S.error_message error)

let installed_one base backend =
  match installed ~sources:[ backend ] base with
  | [ one ] -> one
  | installed -> failf "expected one package, got [%s]" (String.concat "; " (wire installed))

let created (one : S.installed) =
  match one.declaration with
  | S.Created { path } -> path
  | S.Present { path; _ } ->
    failf "%s: a fresh workspace already had a declaration at %s" (B.to_wire one.backend) path

(* A second copy of [backend]'s package somewhere else, as an operator's own
   declaration would point at it; returns its manifest. *)
let copy_package base backend =
  let into = Filename.concat base ("operator-package-" ^ folder backend) in
  List.iter
    (fun (name, contents) -> write (Filename.concat into name) contents)
    (embedded_files backend);
  Filename.concat into manifest_name

let declaration_text ?(enabled = true) ~id ~manifest_path () =
  Printf.sprintf "id = %S\nenabled = %b\nrun_id = %S\nmanifest_path = %S\n\n[binding]\nsources = []\n"
    id enabled id manifest_path

let test_each_requested_source_gets_its_package_and_declaration () =
  with_workspace (fun base ->
    let result = installed base in
    check (list string) "one package per source, in source order" (List.map B.to_wire B.all)
      (wire result);
    List.iter
      (fun (one : S.installed) ->
         let backend = one.backend in
         let name = B.to_wire backend in
         check string (name ^ ": the package name") ("browser-" ^ folder backend)
           (S.package_name backend);
         check string (name ^ ": its own package directory")
           (Filename.concat (packages_directory base) (S.package_name backend))
           one.package_directory;
         let files = embedded_files backend in
         check bool (name ^ ": the binary carries its manifest") true
           (List.mem_assoc manifest_name files);
         List.iter
           (fun (file, contents) ->
              check string (name ^ ": package file " ^ file) contents
                (read (Filename.concat one.package_directory file)))
           files;
         check int (name ^ ": every file written") (List.length files) one.files_written;
         let path = created one in
         check string (name ^ ": its declaration file") (declaration_path base backend) path;
         match Config.load_file ~path with
         | Error message -> failf "%s: the server's reader refuses the declaration: %s" name message
         | Ok declared ->
           check string (name ^ ": the declaration id") (S.package_name backend) declared.id;
           check string (name ^ ": the package id") (S.package_name backend) declared.package.id;
           check bool (name ^ ": the package serves this source") true (serves backend declared);
           check string (name ^ ": the written manifest")
             (Unix.realpath (Filename.concat one.package_directory manifest_name))
             declared.manifest_path;
           check bool (name ^ ": enabled") true declared.enabled)
      result)

let test_a_source_not_requested_is_not_written () =
  with_workspace (fun base ->
    check (list string) "no source, no package" [] (wire (installed ~sources:[] base));
    check bool "no package directory" false (Sys.file_exists (packages_directory base));
    check bool "no Lane directory" false (Sys.file_exists (lane_directory base));
    check (list string) "only the requested source" [ B.to_wire B.Ego ]
      (wire (installed ~sources:[ B.Ego ] base));
    List.iter
      (fun backend ->
         let name = B.to_wire backend in
         check bool (name ^ ": no package") false
           (Sys.file_exists (S.package_directory ~base_path:base backend));
         check bool (name ^ ": no declaration") false
           (Sys.file_exists (declaration_path base backend)))
      (List.filter (fun backend -> backend <> B.Ego) B.all))

let test_a_second_install_changes_nothing () =
  with_workspace (fun base ->
    let paths = List.map created (installed base) in
    let declared = List.map read paths in
    let second = installed base in
    List.iter2
      (fun path (one : S.installed) ->
         let name = B.to_wire one.backend in
         check int (name ^ ": no file rewritten") 0 one.files_written;
         match one.declaration with
         | S.Present { path = present; this_build; _ } ->
           check string (name ^ ": the same declaration") path present;
           check bool (name ^ ": it names this build's package") true this_build
         | S.Created _ -> failf "%s: a second declaration was created" name)
      paths second;
    check (list string) "the declaration bytes are unchanged" declared (List.map read paths))

let test_a_changed_package_file_is_rewritten_and_the_declaration_kept () =
  with_workspace (fun base ->
    let first = installed_one base B.Automation in
    let path = created first in
    let declared = read path in
    let file, original =
      match List.filter (fun (name, _) -> name <> manifest_name) (embedded_files B.Automation) with
      | carried :: _ -> carried
      | [] -> fail "the automation package carries nothing beside its manifest"
    in
    let changed = Filename.concat first.package_directory file in
    write changed (original ^ "\nan older build's text\n");
    let second = installed_one base B.Automation in
    check int "one file rewritten" 1 second.files_written;
    check string "the file is this build's again" original (read changed);
    check string "the declaration bytes are unchanged" declared (read path))

let test_an_existing_declaration_of_a_source_is_left_as_it_is () =
  with_workspace (fun base ->
    let manifest_path = copy_package base B.Automation in
    let own = Filename.concat (lane_directory base) "browser-work.toml" in
    let text = declaration_text ~id:"browser-work" ~manifest_path () in
    write own text;
    (match installed ~sources:[ B.Automation; B.Ego ] base with
     | [ automation; ego ] ->
       (match automation.declaration with
        | S.Created _ -> fail "a second declaration of the automation source was created"
        | S.Present { path; manifest_path = named; this_build; _ } ->
          check string "the operator's declaration" own path;
          check string "its own package" (Unix.realpath manifest_path) named;
          check bool "not this build's package" false this_build);
       check string "the other source is declared beside it" (declaration_path base B.Ego)
         (created ego)
     | installed -> failf "expected two packages, got [%s]" (String.concat "; " (wire installed)));
    check bool "no declaration of the automation package was written" false
      (Sys.file_exists (declaration_path base B.Automation));
    check string "the operator's file is unchanged" text (read own))

let test_two_enabled_declarations_of_one_source_are_refused () =
  with_workspace (fun base ->
    let manifest_path = copy_package base B.Automation in
    List.iter
      (fun id ->
         write (Filename.concat (lane_directory base) (id ^ ".toml"))
           (declaration_text ~id ~manifest_path ()))
      [ "browser-one"; "browser-two" ];
    match install ~sources:[ B.Automation; B.Ego ] base with
    | _, None -> fail "two declarations of one source were accepted"
    | _, Some (S.Declared_more_than_once { backend; paths }) ->
      check string "the doubled source" (B.to_wire B.Automation) (B.to_wire backend);
      check int "both are named" 2 (List.length paths);
      check bool "nothing was written for any source" false
        (Sys.file_exists (packages_directory base))
    | _, Some error -> failf "refused for another reason: %s" (S.error_message error))

(* The server attaches only enabled declarations, so a disabled one beside
   the enabled one does not double the source. *)
let test_a_disabled_declaration_beside_the_enabled_one_is_not_counted () =
  with_workspace (fun base ->
    let manifest_path = copy_package base B.Automation in
    let enabled = Filename.concat (lane_directory base) "browser-one.toml" in
    let disabled = Filename.concat (lane_directory base) "browser-two.toml" in
    write enabled (declaration_text ~id:"browser-one" ~manifest_path ());
    let disabled_text = declaration_text ~enabled:false ~id:"browser-two" ~manifest_path () in
    write disabled disabled_text;
    (match (installed_one base B.Automation).declaration with
     | S.Present { path; enabled = on; _ } ->
       check string "the enabled declaration" enabled path;
       check bool "enabled" true on
     | S.Created _ -> fail "a third declaration of the source was created");
    check string "the disabled file is unchanged" disabled_text (read disabled))

let test_a_disabled_declaration_alone_keeps_the_addon_detached () =
  with_workspace (fun base ->
    let manifest_path = copy_package base B.Automation in
    let disabled = Filename.concat (lane_directory base) "browser-work.toml" in
    write disabled (declaration_text ~enabled:false ~id:"browser-work" ~manifest_path ());
    (match (installed_one base B.Automation).declaration with
     | S.Present { path; enabled; _ } ->
       check string "the disabled declaration" disabled path;
       check bool "still disabled" false enabled
     | S.Created _ -> fail "an enabled declaration was created beside the disabled one");
    check bool "no declaration of the automation package" false
      (Sys.file_exists (declaration_path base B.Automation)))

let test_a_declaration_whose_package_was_removed_is_kept () =
  with_workspace (fun base ->
    let first = installed_one base B.Automation in
    let path = created first in
    let declared = read path in
    remove_tree first.package_directory;
    (match (installed_one base B.Automation).declaration with
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
      declaration_text ~id:(S.package_name B.Automation)
        ~manifest_path:(Filename.concat base "gone/lane.toml") ()
    in
    write broken text;
    (match install ~sources:[ B.Automation ] base with
     | _, Some (S.Declaration_unloadable { path; _ }) -> check string "the broken file" broken path
     | _, None -> fail "a second declaration with the same id was accepted"
     | _, Some error -> failf "refused for another reason: %s" (S.error_message error));
    check bool "no declaration of the automation package" false
      (Sys.file_exists (declaration_path base B.Automation));
    check string "the broken file is unchanged" text (read broken))

(* Sources are applied in order. A refusal of a later one leaves the earlier
   ones written and declared, and says which they are. *)
let test_a_refusal_returns_the_sources_declared_before_it () =
  with_workspace (fun base ->
    write (Filename.concat (lane_directory base) "browser-checkout.toml")
      (declaration_text ~id:(S.package_name B.Ego)
         ~manifest_path:(Filename.concat base "gone/lane.toml") ());
    match install ~sources:[ B.Ego; B.Automation ] base with
    | installed, Some (S.Declaration_unloadable _) ->
      check (list string) "the source applied before the refusal" [ B.to_wire B.Automation ]
        (wire installed);
      check bool "and its declaration is written" true
        (Sys.file_exists (declaration_path base B.Automation));
      check bool "the refused source is not declared" false
        (Sys.file_exists (declaration_path base B.Ego))
    | _, None -> fail "an unloadable declaration of ego was accepted"
    | _, Some error -> failf "refused for another reason: %s" (S.error_message error))

(* A source left out of the plan is neither written nor declared. *)
let test_a_source_left_out_of_the_plan_is_not_declared () =
  with_workspace (fun base ->
    match S.plan ~base_path:base ~sources:[ B.Automation; B.Owned_firefox ] with
    | Error error -> failf "plan refused: %s" (S.error_message error)
    | Ok plan ->
      let { S.installed; refusal } = S.apply (S.without [ B.Owned_firefox ] plan) in
      check bool "nothing refused" true (Option.is_none refusal);
      check (list string) "only the source kept" [ B.to_wire B.Automation ] (wire installed);
      check bool "the left-out source has no package" false
        (Sys.file_exists (S.package_directory ~base_path:base B.Owned_firefox));
      check bool "nor a declaration" false
        (Sys.file_exists (declaration_path base B.Owned_firefox)))

let test_a_workspace_without_a_config_root_is_refused () =
  with_workspace ~config:false (fun base ->
    (match S.plan ~base_path:base ~sources:B.all with
     | Error (S.Config_root_missing _) -> ()
     | Ok _ -> fail "a workspace without a config root was planned"
     | Error error -> failf "refused for another reason: %s" (S.error_message error));
    check bool "no .masc was created" false (Sys.file_exists (Filename.concat base ".masc")))

let test_a_file_this_build_does_not_carry_is_removed () =
  with_workspace (fun base ->
    let package = (installed_one base B.Automation).package_directory in
    let leftover = Filename.concat package "skills/retired/SKILL.md" in
    write leftover "a skill an older build carried\n";
    let again = installed_one base B.Automation in
    check (list string) "the one file removed" [ leftover ] again.files_removed;
    check bool "the file is gone" false (Sys.file_exists leftover);
    check bool "its emptied directory is gone" false
      (Sys.file_exists (Filename.dirname leftover));
    List.iter
      (fun (name, contents) ->
         check string ("package file " ^ name) contents (read (Filename.concat package name)))
      (embedded_files B.Automation))

(* The crunch rule carries only .toml, .json and .md files, so a file of
   another kind added to addons/browser would be left out of the binary
   without a sound. Hidden files (a Finder's .DS_Store) are not part of the
   packages. *)
let test_the_binary_carries_every_file_of_the_source_packages () =
  let source = "../addons/browser" in
  let rec files relative =
    Sys.readdir (if relative = "" then source else Filename.concat source relative)
    |> Array.to_list
    |> List.filter (fun name -> not (String.starts_with ~prefix:"." name))
    |> List.concat_map (fun name ->
      let path = if relative = "" then name else Filename.concat relative name in
      if Sys.is_directory (Filename.concat source path) then files path else [ path ])
  in
  check (list string) "every source file is carried"
    (List.sort String.compare (files ""))
    (List.sort String.compare Embedded_browser_addon.file_list)

let test_a_relative_base_path_is_refused () =
  match S.plan ~base_path:"relative/workspace" ~sources:B.all with
  | Error (S.Base_path_not_absolute _) -> ()
  | Ok _ -> fail "a relative base path was accepted"
  | Error error -> failf "refused for another reason: %s" (S.error_message error)

let () =
  run "browser_addon_setup"
    [ ( "install"
      , [ test_case "each requested source gets its package and declaration" `Quick
            test_each_requested_source_gets_its_package_and_declaration
        ; test_case "a source not requested is not written" `Quick
            test_a_source_not_requested_is_not_written
        ; test_case "a second install changes nothing" `Quick test_a_second_install_changes_nothing
        ; test_case "a changed package file is rewritten and the declaration kept" `Quick
            test_a_changed_package_file_is_rewritten_and_the_declaration_kept
        ; test_case "an existing declaration of a source is left as it is" `Quick
            test_an_existing_declaration_of_a_source_is_left_as_it_is
        ; test_case "two enabled declarations of one source are refused" `Quick
            test_two_enabled_declarations_of_one_source_are_refused
        ; test_case "a disabled declaration beside the enabled one is not counted" `Quick
            test_a_disabled_declaration_beside_the_enabled_one_is_not_counted
        ; test_case "a disabled declaration alone keeps the Add-on detached" `Quick
            test_a_disabled_declaration_alone_keeps_the_addon_detached
        ; test_case "a declaration whose package was removed is kept" `Quick
            test_a_declaration_whose_package_was_removed_is_kept
        ; test_case "an unloadable declaration of the id is left and reported" `Quick
            test_an_unloadable_declaration_of_the_id_is_left_and_reported
        ; test_case "a refusal returns the sources declared before it" `Quick
            test_a_refusal_returns_the_sources_declared_before_it
        ; test_case "a source left out of the plan is not declared" `Quick
            test_a_source_left_out_of_the_plan_is_not_declared
        ; test_case "a workspace without a config root is refused" `Quick
            test_a_workspace_without_a_config_root_is_refused
        ; test_case "a file this build does not carry is removed" `Quick
            test_a_file_this_build_does_not_carry_is_removed
        ; test_case "the binary carries every file of the source packages" `Quick
            test_the_binary_carries_every_file_of_the_source_packages
        ; test_case "a relative base path is refused" `Quick test_a_relative_base_path_is_refused
        ] )
    ]
