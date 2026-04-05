open Alcotest
open Masc_mcp

let find_surface surfaces target_id =
  List.find_opt
    (fun json ->
      Yojson.Safe.Util.(json |> member "id" |> to_string = target_id))
    surfaces

let check_present surfaces target_id =
  match find_surface surfaces target_id with
  | Some _ -> ()
  | None -> fail (Printf.sprintf "%s missing" target_id)

let test_namespace_surface_is_demoted_to_lab () =
  let json = Dashboard_surface_readiness.json () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  match find_surface surfaces "command.namespace" with
  | None -> fail "command.namespace missing"
  | Some surface ->
      check string "exposure_status" "lab"
        Yojson.Safe.Util.(surface |> member "exposure_status" |> to_string);
      check bool "hidden_from_nav" true
        Yojson.Safe.Util.(surface |> member "hidden_from_nav" |> to_bool);
      check bool "meets_main_gate" false
        Yojson.Safe.Util.(surface |> member "meets_main_gate" |> to_bool)

let test_sessions_surface_stays_main () =
  let json = Dashboard_surface_readiness.json ~surface_id:"monitoring.sessions" () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  match find_surface surfaces "monitoring.sessions" with
  | None -> fail "monitoring.sessions missing"
  | Some surface ->
      check string "exposure_status" "main"
        Yojson.Safe.Util.(surface |> member "exposure_status" |> to_string);
      check bool "meets_main_gate" true
        Yojson.Safe.Util.(surface |> member "meets_main_gate" |> to_bool)

let test_visible_surfaces_are_listed () =
  let json = Dashboard_surface_readiness.json () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  List.iter (check_present surfaces)
    [
      "overview";
      "monitoring.sessions";
      "monitoring.agents";
      "monitoring.activity";
      "command.intervene";
      "command.governance";
      "workspace.board";
      "workspace.evidence";
      "workspace.planning";
      "workspace.goals";
      "workspace.worktrees";
      "lab.tools";
      "lab.autoresearch";
      "lab.harness";
      "lab.features";
      "lab.config";
      "logs";
    ]

let test_config_surface_stays_lab () =
  let json = Dashboard_surface_readiness.json ~surface_id:"lab.config" () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  match find_surface surfaces "lab.config" with
  | None -> fail "lab.config missing"
  | Some surface ->
      check string "exposure_status" "lab"
        Yojson.Safe.Util.(surface |> member "exposure_status" |> to_string);
      check bool "hidden_from_nav" false
        Yojson.Safe.Util.(surface |> member "hidden_from_nav" |> to_bool);
      check bool "meets_main_gate" false
        Yojson.Safe.Util.(surface |> member "meets_main_gate" |> to_bool)

let () =
  run "Dashboard_surface_readiness"
    [
      ( "surface_readiness",
        [
          test_case "namespace surface demoted to lab" `Quick
            test_namespace_surface_is_demoted_to_lab;
          test_case "sessions stays main" `Quick test_sessions_surface_stays_main;
          test_case "visible surfaces are listed" `Quick
            test_visible_surfaces_are_listed;
          test_case "config stays lab" `Quick test_config_surface_stays_lab;
        ] );
    ]
