open Alcotest
open Masc_mcp

type surface_contract = {
  id : string;
  label : string;
  exposure_status : string;
  hidden_from_nav : bool;
  meets_main_gate : bool;
  route_hash : string option;
}

let find_surface surfaces target_id =
  List.find_opt (fun surface -> String.equal surface.id target_id) surfaces

let surface_contract_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "id" |> to_string;
    label = json |> member "label" |> to_string;
    exposure_status = json |> member "exposure_status" |> to_string;
    hidden_from_nav = json |> member "hidden_from_nav" |> to_bool;
    meets_main_gate = json |> member "meets_main_gate" |> to_bool;
    route_hash = json |> member "route_hash" |> to_string_option;
  }

let load_surface_contracts_from_json json =
  let open Yojson.Safe.Util in
  json |> member "surfaces" |> to_list |> List.map surface_contract_of_json

let find_verification_ref surface label =
  Yojson.Safe.Util.(surface |> member "verification_refs" |> to_list)
  |> List.find_opt
       (fun json ->
         Yojson.Safe.Util.(json |> member "label" |> to_string = label))

let file_exists path =
  try Sys.file_exists path with Sys_error _ -> false

let repo_root () =
  let rec loop dir =
    let dashboard_dir = Filename.concat dir "dashboard" in
    let src_dir = Filename.concat dashboard_dir "src" in
    let config_dir = Filename.concat src_dir "config" in
    let nav_file = Filename.concat config_dir "navigation.ts" in
    if file_exists nav_file
    then dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then fail "repo root not found"
      else loop parent
  in
  loop (Sys.getcwd ())

let load_nav_contract_from_script () =
  let root = repo_root () in
  let tmp = Filename.temp_file "dashboard-surface-contract" ".json" in
  let cmd =
    Printf.sprintf
      "cd %s && bash scripts/check-dashboard-surface-parity.sh --print-nav-json > %s"
      (Filename.quote root)
      (Filename.quote tmp)
  in
  match Sys.command cmd with
  | 0 ->
      let json = Yojson.Safe.from_file tmp in
      Sys.remove tmp;
      load_surface_contracts_from_json json
  | code ->
      (try Sys.remove tmp with Sys_error _ -> ());
      fail (Printf.sprintf "surface parity helper failed with exit code %d" code)

let load_readiness_contract () =
  Dashboard_surface_readiness.json () |> load_surface_contracts_from_json

let check_surface expected actual =
  check string (expected.id ^ " label") expected.label actual.label;
  check string
    (expected.id ^ " exposure_status")
    expected.exposure_status
    actual.exposure_status;
  check bool
    (expected.id ^ " hidden_from_nav")
    expected.hidden_from_nav
    actual.hidden_from_nav;
  check bool
    (expected.id ^ " meets_main_gate")
    expected.meets_main_gate
    actual.meets_main_gate;
  check (option string)
    (expected.id ^ " route_hash")
    expected.route_hash
    actual.route_hash

let test_surface_contract_matches_navigation_ssot () =
  let expected = load_nav_contract_from_script () in
  let actual = load_readiness_contract () in
  let expected_ids = List.map (fun surface -> surface.id) expected in
  let actual_ids = List.map (fun surface -> surface.id) actual in
  check (list string) "canonical surface ids" expected_ids actual_ids;
  List.iter2 check_surface expected actual

let test_surface_id_filter_returns_single_current_surface () =
  let json = Dashboard_surface_readiness.json ~surface_id:"workspace.verification" () in
  let surfaces = load_surface_contracts_from_json json in
  check int "single surface returned" 1 (List.length surfaces);
  match surfaces with
  | [ surface ] ->
      check string "surface id" "workspace.verification" surface.id;
      check (option string)
        "route hash"
        (Some "#workspace?section=verification")
        surface.route_hash
  | _ -> fail "unexpected surface count"

let test_live_spotcheck_serializes_route_values_as_routes () =
  let json = Dashboard_surface_readiness.json ~surface_id:"overview" () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  match List.find_opt
          (fun surface ->
            Yojson.Safe.Util.(surface |> member "id" |> to_string = "overview"))
          surfaces
  with
  | None -> fail "overview missing"
  | Some surface ->
      (match find_verification_ref surface "live_spotcheck" with
       | None -> fail "overview live_spotcheck missing"
       | Some ref_json ->
           check string "live_spotcheck kind" "route"
             Yojson.Safe.Util.(ref_json |> member "kind" |> to_string))

let test_live_spotcheck_keeps_script_values_as_scripts () =
  let json = Dashboard_surface_readiness.json ~surface_id:"command.operations" () in
  let surfaces = Yojson.Safe.Util.(json |> member "surfaces" |> to_list) in
  match List.find_opt
          (fun surface ->
            Yojson.Safe.Util.(surface |> member "id" |> to_string = "command.operations"))
          surfaces
  with
  | None -> fail "command.operations missing"
  | Some surface ->
      (match find_verification_ref surface "live_spotcheck" with
       | None -> fail "command.operations live_spotcheck missing"
       | Some ref_json ->
           check string "live_spotcheck kind" "script"
             Yojson.Safe.Util.(ref_json |> member "kind" |> to_string))

let test_legacy_surfaces_removed_from_readiness_inventory () =
  let surfaces = load_readiness_contract () in
  let legacy_ids =
    [
      "monitoring.sessions";
      "monitoring.safe_autonomy";
      "monitoring.activity";
      "command.intervene";
      "command.namespace";
      "command.governance";
      "workspace.evidence";
      "workspace.goals";
      "workspace.worktrees";
      "lab.features";
      "lab.config";
    ]
  in
  List.iter
    (fun legacy_id ->
      check bool (legacy_id ^ " removed") true
        (Option.is_none (find_surface surfaces legacy_id)))
    legacy_ids

let test_safe_autonomy_surface_matches_monitoring_contract () =
  let surfaces =
    Dashboard_surface_readiness.json ~surface_id:"monitoring.safe-autonomy" ()
    |> load_surface_contracts_from_json
  in
  match find_surface surfaces "monitoring.safe-autonomy" with
  | None -> fail "monitoring.safe-autonomy missing"
  | Some surface ->
      check string "exposure_status" "main" surface.exposure_status;
      check bool "hidden_from_nav" false surface.hidden_from_nav;
      check bool "meets_main_gate" true surface.meets_main_gate

let () =
  run "Dashboard_surface_readiness"
    [
      ( "surface_readiness",
        [
          test_case "surface contract matches navigation ssot" `Quick
            test_surface_contract_matches_navigation_ssot;
          test_case "surface_id filter returns current verification surface" `Quick
            test_surface_id_filter_returns_single_current_surface;
          test_case "route live spotchecks stay routes" `Quick
            test_live_spotcheck_serializes_route_values_as_routes;
          test_case "script live spotchecks stay scripts" `Quick
            test_live_spotcheck_keeps_script_values_as_scripts;
          test_case "legacy surfaces removed from readiness inventory" `Quick
            test_legacy_surfaces_removed_from_readiness_inventory;
          test_case "safe autonomy matches monitoring contract" `Quick
            test_safe_autonomy_surface_matches_monitoring_contract;
        ] );
    ]
