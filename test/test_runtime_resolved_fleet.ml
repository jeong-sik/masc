(* GET /api/v1/runtime/resolved names the keeper fleet in two places: one
   assignment row per keeper, and the lanes those assignments resolve to. The
   fleet is every keeper with metadata in the keeper directory and every
   keeper [runtime.assignments] names. *)

open Alcotest
open Masc

let runtime_toml =
  "[providers.fleet_claude]\n\
   protocol = \"claude-code\"\n\
   command = \"/usr/bin/true\"\n\
   is-non-interactive = true\n\
   \n\
   [providers.fleet_codex]\n\
   protocol = \"codex-app-server\"\n\
   command = \"/usr/bin/true\"\n\
   is-non-interactive = true\n\
   \n\
   [models.sonnet]\n\
   api-name = \"sonnet\"\n\
   max-context = 200000\n\
   \n\
   [models.sol]\n\
   api-name = \"gpt-5.6-sol\"\n\
   max-context = 400000\n\
   \n\
   [fleet_claude.sonnet]\n\
   \n\
   [fleet_codex.sol]\n\
   \n\
   [runtime]\n\
   default = \"fleet_claude.sonnet\"\n\
   \n\
   [runtime.assignments]\n\
   assigned = \"fleet_codex.sol\"\n\
   both = \"fleet_codex.sol\"\n"
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path)
  else Sys.remove path
;;

(* Loads [runtime_toml] and writes a metadata file for each of
   [directory_keepers] into a fresh workspace's keeper directory. *)
let with_fleet ~directory_keepers f =
  let snapshot = Runtime.For_testing.snapshot () in
  let base = Filename.temp_dir "runtime-resolved-fleet" "" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      remove_tree base)
    (fun () ->
       let config_path = Filename.concat base "runtime.toml" in
       Out_channel.with_open_bin config_path (fun oc -> output_string oc runtime_toml);
       (match Runtime.init_default ~config_path with
        | Ok () -> ()
        | Error detail -> failf "fixture runtime.toml should load: %s" detail);
       let config = Workspace.default_config base in
       let keepers = Keeper_fs.keeper_dir config in
       List.iter
         (fun keeper ->
            Out_channel.with_open_bin
              (Filename.concat keepers (keeper ^ ".json"))
              (fun (_ : Out_channel.t) -> ()))
         directory_keepers;
       f config)
;;

let resolved config =
  Server_dashboard_runtime_resolved_json.build
    ~generated_at_iso:"2026-09-30T00:00:00Z"
    ~config
;;

let assignment_rows json =
  Yojson.Safe.Util.(json |> member "assignments" |> to_list)
  |> List.map (fun row ->
    Yojson.Safe.Util.
      ( row |> member "keeper" |> to_string
      , row |> member "assignment_source" |> to_string
      , row |> member "resolved" |> member "id" |> to_string ))
;;

let lanes json =
  Yojson.Safe.Util.(json |> member "lanes" |> to_list)
  |> List.map (fun lane ->
    Yojson.Safe.Util.(lane |> member "id" |> to_string, lane |> member "declared" |> to_bool))
;;

let test_every_keeper_has_a_row_and_its_lane () =
  with_fleet ~directory_keepers:[ "both"; "rider" ] @@ fun config ->
  let json = resolved config in
  check
    (list (triple string string string))
    "one row per keeper in the directory or the assignments"
    [ "assigned", "explicit", "fleet_codex.sol"
    ; "both", "explicit", "fleet_codex.sol"
    ; "rider", "default", "fleet_claude.sonnet"
    ]
    (assignment_rows json);
  check
    (list (pair string bool))
    "no lane is declared, so each lane a row resolves to is listed once"
    [ "fleet_claude.sonnet", false; "fleet_codex.sol", false ]
    (lanes json)
;;

let () =
  run
    "runtime resolved fleet"
    [ ( "fleet"
      , [ test_case
            "every keeper has a row and its lane"
            `Quick
            test_every_keeper_has_a_row_and_its_lane
        ] )
    ]
;;
