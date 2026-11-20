(* The seed a release install depends on.

   A binary installed away from its repo finds no filesystem [config/] to copy,
   so [Server_runtime_config_root_bootstrap.seed_missing_from_embedded] is the
   only thing standing between a fresh base path and a startup that dies on "no
   runtime config path". These cases pin what it writes, what it refuses to
   write, and that a second pass leaves the operator's edits alone. *)

open Alcotest
module Seed = Server_runtime_config_root_bootstrap

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let fresh_dst () = Filename.temp_dir "masc-embedded-seed-" ""

let entries_of dir =
  if Sys.file_exists dir && Sys.is_directory dir
  then Array.to_list (Sys.readdir dir)
  else []

let test_writes_runtime_toml () =
  let dst = fresh_dst () in
  let written = Seed.seed_missing_from_embedded ~dst in
  check bool "wrote something" true (written > 0);
  check bool "runtime.toml present" true
    (Sys.file_exists (Filename.concat dst "runtime.toml"));
  check bool "prompts present" true
    (Sys.is_directory (Filename.concat dst "prompts"))

(* The seed is filtered because the repo's own keeper examples autoboot into
   a sandbox the host may not have. Since #34310 a fresh workspace still gets a
   roster: exactly the manifests [keepers-default/] holds, landing under
   [keepers/], and every one of them waits for an operator to start it. The expected names come from the
   embedded listing through the same mapping the seeder uses, so a manifest
   added to the default set is covered without editing this case. *)
let test_writes_the_default_roster_with_autoboot_off () =
  let dst = fresh_dst () in
  ignore (Seed.seed_missing_from_embedded ~dst : int);
  let expected =
    Embedded_config.file_list
    |> List.filter_map Common.fresh_config_root_keeper_seed_target
    |> List.map Filename.basename
    |> List.sort_uniq String.compare
  in
  check bool "the default roster names at least one Keeper" true (expected <> []);
  let keepers = Filename.concat dst "keepers" in
  check (list string) "exactly the default roster" expected
    (List.sort String.compare (entries_of keepers));
  List.iter
    (fun name ->
       match Keeper_toml_loader.parse_toml (read_file (Filename.concat keepers name)) with
       | Error detail -> fail (name ^ " did not parse: " ^ detail)
       | Ok doc ->
         (* #34392 retired [autoboot_enabled] and [proactive_enabled] for
            [activation_mode], so the bool read answered [None] for every
            manifest and this case could no longer be won. "Waits to be
            started" is [manual]. *)
         check (option string) (name ^ " waits to be started") (Some "manual")
           (Keeper_toml_loader.toml_string_opt doc "keeper.activation_mode"))
    expected

let test_writes_no_dune_file () =
  let dst = fresh_dst () in
  ignore (Seed.seed_missing_from_embedded ~dst : int);
  check bool "no dune at the config root" false
    (Sys.file_exists (Filename.concat dst "dune"))

let test_second_pass_keeps_operator_edits () =
  let dst = fresh_dst () in
  let first = Seed.seed_missing_from_embedded ~dst in
  let runtime_toml = Filename.concat dst "runtime.toml" in
  let edited = "# edited by the operator\n" in
  let oc = open_out_bin runtime_toml in
  output_string oc edited;
  close_out oc;
  let second = Seed.seed_missing_from_embedded ~dst in
  check bool "first pass wrote files" true (first > 0);
  check int "second pass wrote nothing" 0 second;
  check string "operator edit survives" edited (read_file runtime_toml)

(* The narrow backfill for a config root that already exists repairs the runtime
   configuration whose absence stops startup and touches nothing else. *)
let test_backfill_repairs_only_startup_required () =
  let config_root = fresh_dst () in
  let written = Seed.backfill_startup_required_from_embedded ~config_root in
  check int "wrote the startup-required file" 1 written;
  check bool "runtime.toml present" true
    (Sys.file_exists (Filename.concat config_root "runtime.toml"));
  check bool "prompts not filled in" false
    (Sys.file_exists (Filename.concat config_root "prompts"));
  check int "second call is a no-op" 0
    (Seed.backfill_startup_required_from_embedded ~config_root)

(* [masc auth bootstrap] places the embedded runtime.toml for an account
   workspace. The account server reads what people may connect at the path
   [Server_runtime_setup_actions.config_path] names, so a placement there on
   an empty base path is read back by that reader, and the file this build
   embeds offers a person a provider with a model. *)
let placed path =
  match Seed.place_embedded_runtime_toml ~path with
  | Ok placement -> placement
  | Error (Seed.Not_published reason) -> fail ("no entry was made: " ^ reason)
  | Error (Seed.Not_synced reason) -> fail ("the directory was not synced: " ^ reason)

let beside path = Array.to_list (Sys.readdir (Filename.dirname path))

let test_placed_runtime_toml_is_what_people_connect () =
  let base_path = fresh_dst () in
  let path = Server_runtime_setup_actions.config_path ~base_path in
  (match placed path with
   | Seed.Embedded_written -> ()
   | Seed.Existing_kept -> fail "an empty base path holds no runtime.toml to keep");
  check (option string) "the embedded file, whole"
    (Embedded_config.read "runtime.toml") (Some (read_file path));
  check int "readable by its owner only" 0o600 (Unix.stat path).st_perm;
  check (list string) "the staged file is not left beside it" [ "runtime.toml" ] (beside path);
  match Server_runtime_setup_actions.config ~base_path with
  | Error error -> fail (Server_runtime_setup_actions.error_message error)
  | Ok config ->
    check bool "a person may connect a provider that offers a model" true
      (List.exists
         (fun (integration : Server_person_integrations.integration) ->
            integration.models <> [])
         (Server_person_integrations.of_config config))

(* An entry at the path is the operator's. A file keeps its bytes, a directory
   stays one, and a link keeps where it points, also when nothing is there.
   Nothing is written beside it. [place] is the placement, which looks at the
   path before it writes, or its writing step alone, where the rename meets
   the entry: an entry that came to be there after the look. *)
let entries_are_kept ~place () =
  let base_path = fresh_dst () in
  let path = Server_runtime_setup_actions.config_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  let kept what =
    (match place path with
     | Seed.Existing_kept -> ()
     | Seed.Embedded_written -> fail (what ^ " was replaced"));
    check (list string) (what ^ ": nothing is written beside it") [ "runtime.toml" ]
      (beside path)
  in
  let operator_runtime = "# operator runtime\n" in
  Fs_compat.save_file path operator_runtime;
  kept "the operator's runtime.toml";
  check string "operator runtime.toml untouched" operator_runtime (read_file path);
  Sys.remove path;
  Unix.mkdir path 0o700;
  kept "a directory";
  check bool "the directory is still one" true ((Unix.lstat path).st_kind = Unix.S_DIR);
  Unix.rmdir path;
  let elsewhere = Filename.concat base_path "operator.toml" in
  Fs_compat.save_file elsewhere operator_runtime;
  Unix.symlink elsewhere path;
  kept "a link to the operator's file";
  check string "the link points where it did" elsewhere (Unix.readlink path);
  check string "the file it points at is untouched" operator_runtime (read_file elsewhere);
  Sys.remove path;
  let gone = Filename.concat base_path "gone" in
  Unix.symlink gone path;
  kept "a link whose target is gone";
  check string "that link points where it did" gone (Unix.readlink path);
  check bool "its target was not made" false (Sys.file_exists gone)

let test_placement_keeps_what_is_there = entries_are_kept ~place:placed

let test_the_rename_keeps_what_is_there =
  entries_are_kept ~place:(fun path -> Seed.publish_runtime_toml ~path "# a candidate\n")

let not_published path =
  match Seed.place_embedded_runtime_toml ~path with
  | Error (Seed.Not_published (_ : string)) -> true
  | Error (Seed.Not_synced (_ : string))
  | Ok (Seed.Embedded_written | Seed.Existing_kept) -> false

(* A path where no entry can be made is an [Error] that says no file was
   made. Under a file the path cannot be looked at; under a link whose target
   is gone it can, and the staging beside it fails. *)
let test_placement_reports_a_path_it_cannot_write () =
  let base_path = fresh_dst () in
  let not_published parent = not_published (Filename.concat parent "runtime.toml") in
  let file = Filename.concat base_path "file" in
  Fs_compat.save_file file "";
  check bool "under a file" true (not_published file);
  check string "the file is untouched" "" (read_file file);
  let link = Filename.concat base_path "link" in
  let gone = Filename.concat base_path "gone" in
  Unix.symlink gone link;
  check bool "under a link whose target is gone" true (not_published link);
  check string "the link points where it did" gone (Unix.readlink link);
  check bool "its target was not made" false (Sys.file_exists gone)

(* A placement that makes directories and then no file removes them: a base
   path it leaves holds no config root that a later boot would take for the
   operator's. Under this umask a directory is made without the write bit,
   so the first stops the staging and the second stops the directory below
   it. The superuser writes there all the same. *)
let test_failed_placement_removes_the_directories_it_made () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let base_path = fresh_dst () in
  let without_write_bit = 0o222 in
  let earlier = Unix.umask without_write_bit in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.umask earlier : int))
    (fun () ->
      let one = Filename.concat base_path "one" in
      check bool "one directory to make" true (not_published (Filename.concat one "runtime.toml"));
      check bool "it is gone" false (Sys.file_exists one);
      let outer = Filename.concat base_path "outer" in
      check bool "two directories to make" true
        (not_published (Filename.concat (Filename.concat outer "inner") "runtime.toml"));
      check bool "both are gone" false (Sys.file_exists outer))

(* The packages the binary ships are whatever the embedded listing holds, so
   the expectation is read from that listing rather than typed in: a typed
   count went stale twice as packages were added (#34256 shipped five,
   #34480 and #34498 made it seven). *)
let embedded_packages () =
  Embedded_skills.file_list
  |> List.filter_map (fun rel ->
       (* The seeder's own rule: a package is a directory that holds SKILL.md
          directly, not any first path segment. *)
       match String.split_on_char '/' rel with
       | [ package; "SKILL.md" ] -> Some package
       | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ -> None)
  |> List.sort_uniq String.compare

let reconciled base_path =
  match Seed.install_builtin_skills ~on_wait:(fun (_ : string) -> ()) ~base_path with
  | Ok reports -> reports
  | Error error -> fail (Builtin_skill_package.error_message error)

let bundled_verdicts reports =
  List.filter_map
    (function
      | Builtin_skill_package.Bundled { name; result = Ok verdict } -> Some (name, verdict)
      | Builtin_skill_package.Bundled { name; result = Error error } ->
        fail (name ^ ": " ^ Builtin_skill_package.error_message error)
      | Builtin_skill_package.Retired _ | Builtin_skill_package.Interrupted _
      | Builtin_skill_package.Unfinished _ -> None)
    reports

let test_builtin_skill_package () =
  let base_path = fresh_dst () in
  let packages = embedded_packages () in
  check bool "the embedded listing names at least one package" true (packages <> []);
  let first = bundled_verdicts (reconciled base_path) in
  check (list string) "every embedded package is reported in order" packages (List.map fst first);
  List.iter
    (fun (name, verdict) ->
       match verdict with
       | Builtin_skill_package.Install_missing -> ()
       | _ -> fail (name ^ " must be installed into an empty root"))
    first;
  let root = Filename.concat base_path ".masc/skills" in
  List.iter
    (fun rel ->
       match Embedded_skills.read rel with
       | None -> fail "embedded listing must resolve"
       | Some expected ->
         check string rel expected (read_file (Filename.concat root rel)))
    Embedded_skills.file_list;
  let edited = List.hd packages in
  let body = Filename.concat root (edited ^ "/SKILL.md") in
  Fs_compat.save_file body "operator's own skill";
  let second = bundled_verdicts (reconciled base_path) in
  List.iter
    (fun (name, verdict) ->
       match String.equal name edited, verdict with
       | true, Builtin_skill_package.Keep_modified _ -> ()
       | false, Builtin_skill_package.Up_to_date -> ()
       | _ -> fail (name ^ ": an unchanged release keeps edits and touches nothing else"))
    second;
  check string "operator body survives" "operator's own skill" (read_file body);
  check (list string) "all packages present without staging residue"
    packages
    (List.sort String.compare (entries_of root))

(* Server startup on a root that already exists. It only adds: a package
   whose directory is gone is published again and an untracked tree equal to
   this release is recorded, but a recorded package this release does not ship
   stays where it is until [masc init] moves it aside. *)
let test_existing_root_startup_only_adds () =
  let base_path = fresh_dst () in
  let config_root = Filename.concat base_path ".masc/config" in
  Fs_compat.mkdir_p config_root;
  let runtime_toml = Filename.concat config_root "runtime.toml" in
  let operator_runtime = "# operator runtime\n" in
  Fs_compat.save_file runtime_toml operator_runtime;
  let retired =
    match
      Builtin_skill_package.make ~name:"retired-fixture"
        ~files:[ "SKILL.md", "a package an earlier release shipped" ]
    with
    | Ok package -> package
    | Error reason -> fail reason
  in
  (match
     Builtin_skill_package.install ~on_wait:(fun (_ : string) -> ()) ~base_path
       (Seed.builtin_skills () @ [ retired ])
   with
   | Ok _ -> ()
   | Error error -> fail (Builtin_skill_package.error_message error));
  let packages = embedded_packages () in
  let untracked = List.hd packages in
  let removed = List.nth packages (List.length packages - 1) in
  check bool "the fixture needs two different packages" false (String.equal untracked removed);
  let state = Filename.concat base_path ".masc/skill-packages" in
  let skills = Filename.concat base_path ".masc/skills" in
  let untracked_receipt = Filename.concat state (untracked ^ ".sha256") in
  let recorded = read_file untracked_receipt in
  Sys.remove untracked_receipt;
  Fs_compat.remove_tree (Filename.concat skills removed);
  Seed.bootstrap_base_path_config_root ~base_path;
  check string "operator runtime.toml untouched" operator_runtime (read_file runtime_toml);
  check string "identical untracked package recorded again" recorded
    (read_file untracked_receipt);
  check bool "a package whose directory was gone is published again" true
    (Sys.file_exists (Filename.concat skills (removed ^ "/SKILL.md")));
  check string "the package this release does not ship stays in the Skill source"
    "a package an earlier release shipped"
    (read_file (Filename.concat skills "retired-fixture/SKILL.md"));
  check bool "its receipt stays" true
    (Sys.file_exists (Filename.concat state "retired-fixture.sha256"));
  check bool "startup made no backup" false
    (Sys.file_exists (Filename.concat state "previous"));
  let retirements =
    List.filter_map
      (function
        | Builtin_skill_package.Retired { name; result } -> Some (name, result)
        | Builtin_skill_package.Bundled _ | Builtin_skill_package.Interrupted _
        | Builtin_skill_package.Unfinished _ -> None)
      (reconciled base_path)
  in
  (match retirements with
   | [ "retired-fixture", Ok (Builtin_skill_package.Retire_recorded { backup = Some backup }) ] ->
     check string "masc init keeps the retired package in its backup entry"
       "a package an earlier release shipped"
       (read_file (Filename.concat backup "SKILL.md"))
   | _ -> fail "masc init must retire the package startup left in place");
  check (list string) "every shipped package is in place and nothing else"
    packages
    (List.sort String.compare (entries_of skills))

let test_relative_base_path_boot_and_resolver_agree () =
  let root = fresh_dst () in
  let saved_cwd = Sys.getcwd () in
  Unix.chdir root;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir saved_cwd;
      Config_dir_resolver.reset ();
      Fs_compat.remove_tree root)
    (fun () ->
      let cwd = Unix.getcwd () in
      let expected_config_root = Filename.concat cwd "ws/.masc/config" in
      Fs_compat.mkdir_p (Filename.concat expected_config_root "prompts");
      Fs_compat.mkdir_p (Filename.concat expected_config_root "keepers");
      Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
      Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
      Masc_test_deps.with_process_env "MASC_CONFIG_BOOTSTRAP" (Some "empty") @@ fun () ->
      Config_dir_resolver.reset ();
      (match Seed.missing_runtime_toml_at_boot ~base_path:"ws" with
       | Seed.Written_at_boot -> ()
       | Seed.Left_missing reason ->
         fail ("expected existing relative ws/.masc/config to be recognized: " ^ reason));
      let resolution = Seed.startup_config_resolution ~base_path:"ws" in
      check string "startup config root matches bootstrap path"
        expected_config_root resolution.config_root.path;
      check bool "startup config root exists" true resolution.config_root.exists)

let () =
  run "Config root embedded seed"
    [ ( "builtin_skills"
      , [ test_case "complete package and operator ownership" `Quick test_builtin_skill_package
        ; test_case "startup on an existing root only adds packages" `Quick
            test_existing_root_startup_only_adds
        ; test_case "relative base_path bootstrap and resolver agree" `Quick
            test_relative_base_path_boot_and_resolver_agree
        ] )
    ; ( "seed_missing_from_embedded"
      , [ test_case "writes runtime.toml and prompts" `Quick
            test_writes_runtime_toml
        ; test_case "writes the default roster with autoboot off" `Quick
            test_writes_the_default_roster_with_autoboot_off
        ; test_case "writes no dune file" `Quick test_writes_no_dune_file
        ; test_case "second pass keeps operator edits" `Quick
            test_second_pass_keeps_operator_edits
        ] )
    ; ( "backfill_startup_required_from_embedded"
      , [ test_case "repairs only the startup-required files" `Quick
            test_backfill_repairs_only_startup_required
        ] )
    ; ( "place_embedded_runtime_toml"
      , [ test_case "the placed file is what people connect" `Quick
            test_placed_runtime_toml_is_what_people_connect
        ; test_case "keeps what is there" `Quick test_placement_keeps_what_is_there
        ; test_case "the rename keeps what came to be there" `Quick
            test_the_rename_keeps_what_is_there
        ; test_case "a failed placement removes the directories it made" `Quick
            test_failed_placement_removes_the_directories_it_made
        ; test_case "reports a path it cannot write" `Quick
            test_placement_reports_a_path_it_cannot_write
        ] )
    ]
