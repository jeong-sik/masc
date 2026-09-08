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

(* The whole reason the seed is filtered: the shipped keeper examples autoboot
   into a sandbox the host may not have, so a fresh workspace gets no roster. *)
let test_writes_no_keeper_manifests () =
  let dst = fresh_dst () in
  ignore (Seed.seed_missing_from_embedded ~dst : int);
  check (list string) "no keeper manifests" []
    (entries_of (Filename.concat dst "keepers"))

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

(* The narrow backfill for a config root that already exists: it repairs the two
   files whose absence stops startup and touches nothing else. *)
let test_backfill_repairs_only_startup_required () =
  let config_root = fresh_dst () in
  let written = Seed.backfill_startup_required_from_embedded ~config_root in
  check int "wrote both startup-required files" 2 written;
  check bool "runtime.toml present" true
    (Sys.file_exists (Filename.concat config_root "runtime.toml"));
  check bool "overlay present" true
    (Sys.file_exists (Filename.concat config_root "agent-core-models-overlay.toml"));
  check bool "prompts not filled in" false
    (Sys.file_exists (Filename.concat config_root "prompts"));
  check int "second call is a no-op" 0
    (Seed.backfill_startup_required_from_embedded ~config_root)

let test_builtin_skill_package () =
  let base_path = fresh_dst () in
  check int "five complete first-party packages" 5
    (Seed.seed_missing_builtin_skills ~base_path);
  let root = Filename.concat base_path ".masc/skills" in
  List.iter
    (fun rel ->
       match Embedded_skills.read rel with
       | None -> fail "embedded listing must resolve"
       | Some expected ->
         check string rel expected (read_file (Filename.concat root rel)))
    Embedded_skills.file_list;
  let body = Filename.concat root "browser-lanes/SKILL.md" in
  Fs_compat.save_file body "operator's own skill";
  let resource = Filename.concat root "browser-lanes/references/advanced.md" in
  Sys.remove resource;
  check int "existing package is not refilled" 0
    (Seed.seed_missing_builtin_skills ~base_path);
  check string "operator body survives" "operator's own skill" (read_file body);
  check bool "operator resource deletion survives" false (Sys.file_exists resource);
  check (list string) "all packages present without staging residue"
    [ "browser-design"; "browser-lanes"; "evidence-review"; "frontend-implement"; "frontend-verify" ]
    (List.sort String.compare (entries_of root))

let () =
  run "Config root embedded seed"
    [ ( "builtin_skills"
      , [ test_case "complete package and operator ownership" `Quick test_builtin_skill_package ] )
    ; ( "seed_missing_from_embedded"
      , [ test_case "writes runtime.toml and prompts" `Quick
            test_writes_runtime_toml
        ; test_case "writes no keeper manifests" `Quick
            test_writes_no_keeper_manifests
        ; test_case "writes no dune file" `Quick test_writes_no_dune_file
        ; test_case "second pass keeps operator edits" `Quick
            test_second_pass_keeps_operator_edits
        ] )
    ; ( "backfill_startup_required_from_embedded"
      , [ test_case "repairs only the startup-required files" `Quick
            test_backfill_repairs_only_startup_required
        ] )
    ]
