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

let () =
  run "Config root embedded seed"
    [ ( "builtin_skills"
      , [ test_case "complete package and operator ownership" `Quick test_builtin_skill_package
        ; test_case "startup on an existing root only adds packages" `Quick
            test_existing_root_startup_only_adds
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
    ]
