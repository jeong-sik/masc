open Alcotest
open Masc
module A = Keeper_memory_execution_availability
module C = Keeper_librarian_addon
module R = Lane_addon_runtime
let require = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let snapshot declarations : Lane_addon_config.snapshot =
  {declarations;issues=[];paths=List.map (fun (d : Lane_addon_config.declaration) -> d.source_path) declarations;complete=true}
let empty : R.tool_execution_snapshot = {serving=[];conflicts=[];unready=[]}
let declaration ?(extra="") () =
  let manifest=Sys.getenv "MASC_TEST_LIBRARIAN_PACKAGE" in
  let manifest=if Filename.is_relative manifest then Filename.concat (Sys.getcwd ()) manifest else manifest in
  Lane_addon_config.load_source ~source_path:"/memory-test/keeper-librarian.toml"
    ~source_text:(Printf.sprintf "id=\"memory-worker\"\nrun_id=\"memory\"\nmanifest_path=%S\n%s\n[binding]\nsources=[]\n" manifest extra)
  |> require
let observe ?(setting=Env_config_keeper.KeeperMemoryOs.Enabled) ?(route=fun _ -> Ok ()) ~mode declarations =
  A.observe ~setting ~declarations:(snapshot declarations) ~route ~mode
let state operation values = List.assoc operation values
let unavailable expected = function
  | A.Unavailable (_,actual) -> check bool "dependency cause is retained" true (actual=expected)
  | Disabled | Invalid_setting | Configuration_admitted _ | Serving _ -> fail "expected unavailable dependency"

let test_absent_off_and_unobserved_are_distinct () =
  unavailable A.Addon_unattached (state C.Durable (observe ~mode:A.Preflight []));
  unavailable (A.Addon_off ["memory-worker"])
    (state C.Durable (observe ~mode:A.Preflight [declaration ~extra:"enabled=false" ()]));
  let d=declaration () in
  (match state C.Durable (observe ~mode:A.Preflight [d]) with
   | A.Configuration_admitted binding ->
     check string "actual installation owns route" "runtime.addon_exact_lanes.memory-worker.durable" binding.route_table
   | Disabled | Invalid_setting | Unavailable _ | Serving _ -> fail "valid declaration was not admitted");
  unavailable (A.Export_unavailable C.Unattached)
    (state C.Durable (observe ~mode:(A.Live empty) [d]));
  (match state C.Durable (observe ~setting:Env_config_keeper.KeeperMemoryOs.Disabled ~mode:(A.Live empty) [] ) with
   | A.Disabled -> ()
   | Invalid_setting | Unavailable _ | Configuration_admitted _ | Serving _ -> fail "explicit Memory Off was overridden")

let test_actual_package_requires_both_routes () =
  let d=declaration () in
  let calls=ref [] in
  let route (lane : Runtime_schema.addon_lane) =
    calls := (lane.declaration_id,lane.output) :: !calls;
    if String.equal lane.output "durable" then Error Lane_addon_exact.Lane_unconfigured else Ok () in
  let values=observe ~route ~mode:A.Preflight [d] in
  check (list (pair string string)) "package operations bind distinct routes"
    ["memory-worker","admission";"memory-worker","durable"] (List.rev !calls);
  unavailable (A.Route_unavailable Lane_addon_exact.Lane_unconfigured) (state C.Durable values);
  let disabled=observe ~route:(fun _ -> Error Lane_addon_exact.Lane_off) ~mode:A.Preflight [d] |> A.to_json in
  check bool "explicit route off asks for no repair" false
    (member "operator_action_required" disabled |> Yojson.Safe.Util.to_bool)

let test_invalid_configuration_and_deselection_are_distinct () =
  let issue : Lane_addon_config.issue =
    {source_path="/memory-test/broken.toml";id=None;message="invalid declaration"} in
  let declarations={ (snapshot []) with complete=false;issues=[issue] } in
  let values=A.observe ~setting:Env_config_keeper.KeeperMemoryOs.Enabled
      ~declarations ~route:(fun _ -> fail "unreadable configuration admitted a route") ~mode:A.Preflight in
  unavailable (A.Configuration_unreadable [issue]) (state C.Admission values);
  let deselected=declaration ~extra:"exact_outputs=[]" () in
  unavailable (A.Output_not_selected "durable")
    (state C.Durable (observe ~mode:A.Preflight [deselected]));
  let d=declaration () in
  unavailable (A.Route_unavailable Lane_addon_exact.No_admitted_slots)
    (state C.Durable (observe ~route:(fun _ -> Error Lane_addon_exact.No_admitted_slots)
      ~mode:A.Preflight [d]))

let test_real_manifest_parse_error_stays_in_authenticated_diagnostics () =
  let root=Filename.temp_dir "memory-private-config-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let directory=Filename.concat root "lane-addons" in
    Fs_compat.mkdir_p directory;
    let manifest=Filename.concat root "private-package.toml" in
    let sentinel="PRIVATE_MARKER" in
    let write path bytes=Out_channel.with_open_bin path (fun channel -> output_string channel bytes) in
    write manifest (Printf.sprintf
      "id=\"unrelated\"\nrevision=\"1\"\ntitle=\"Unrelated package\"\ncontributions=[\"observe\"]\nimage=\"fixture\"\ncommand=[\"fixture\"]\n[interface]\nbinding_schema='''%s'''\n" sentinel);
    write (Filename.concat directory "unrelated.toml") (Printf.sprintf
      "id=\"unrelated\"\nrun_id=\"unrelated\"\nmanifest_path=%S\n[binding]\nsources=[]\n" manifest);
    let declarations=Lane_addon_config.load ~directory in
    check bool "the real parser retains offending input in its operator diagnostic" true
      (List.exists (fun (issue : Lane_addon_config.issue) ->
        Astring.String.is_infix ~affix:sentinel issue.message) declarations.issues);
    let public=A.observe ~setting:Env_config_keeper.KeeperMemoryOs.Enabled ~declarations
      ~route:(fun _ -> fail "invalid configuration cannot admit routes") ~mode:A.Preflight |> A.to_json in
    check string "public health still names configuration failure" "degraded" (text "status" public);
    let bytes=Yojson.Safe.to_string public in
    check bool "private parser input is not public health" false (Astring.String.is_infix ~affix:sentinel bytes);
    check bool "private source paths are not public health" false (Astring.String.is_infix ~affix:root bytes);
    let operation=member "operations" public |> Yojson.Safe.Util.to_list |> List.hd in
    let issue=member "detail" operation |> Yojson.Safe.Util.to_list |> List.hd in
    check string "public failure retains the declaration identity" "unrelated" (text "installation_id" issue);
    check string "public failure is a fixed category" "declaration_unavailable" (text "reason" issue))

let test_starting_failed_and_conflict_are_not_absent () =
  let d=declaration () in
  let unready reason : Lane_addon_unready.t =
    {installation=d.id;instance_id="worker";package_id=C.package_id;
     declared_tools=[C.tool C.Admission;C.tool C.Durable];service=Lane_addon_types.Mcp_tools;reason} in
  List.iter (fun reason ->
    let entry=unready reason in
    let live={empty with unready=[entry]} in
    (match C.select C.Admission live with
     | Error (C.Unready (actual,[])) -> check string "the owner remains named" "memory-worker" actual.installation
     | Error (Unattached | Export_conflict _ | Wrong_package _ | Manual_installation | Unready _) | Ok _ ->
       fail "a known unavailable worker became absent");
    unavailable (A.Export_unavailable (C.Unready (entry,[])))
      (state C.Durable (observe ~mode:(A.Live live) [d])))
    [Lane_addon_unready.Starting;Failed {cause=Lane_addon_lifecycle.Worker_failed "fixture";first=None}];
  let conflict : Lane_addon_tool_export.conflict =
    {name=C.tool C.Durable;instances=["one";"two"];reason=Multiple_installations} in
  unavailable (A.Export_unavailable (C.Export_conflict conflict))
    (state C.Durable (observe ~mode:(A.Live {empty with conflicts=[conflict]}) [d]))

let test_serving_retains_provider_cause_without_leaking_body () =
  let d=declaration () in
  let name=C.tool C.Durable in
  let tool=Mcp_protocol.Mcp_types.tool_of_yojson
      (`Assoc ["name",`String name;"inputSchema",`Assoc ["type",`String "object"]]) |> require in
  let export=Lane_addon_tool_export.create
      ~owner:(Lane_addon_tool_export.create_owner ~instance_id:"original-worker") ~tool in
  let entry : R.tool_execution = {export;installation_id=Some d.id;package_id=C.package_id;
    configuration_revision=Some d.revision;last_cycle_at=Some 42.;host_issue=None;
    exact_waiting=[{request_id="original-request";output="durable";
      reason=Lane_addon_exact.Provider_refused (Provider_unavailable {detail="PRIVATE PROVIDER BODY"})}]} in
  let values=observe ~mode:(A.Live {empty with serving=[entry]}) [d] in
  (match state C.Durable values with
   | A.Serving (_,actual) -> check string "original request remains joined" "original-request"
       (List.hd actual.exact_waiting).request_id
   | Disabled | Invalid_setting | Unavailable _ | Configuration_admitted _ -> fail "serving worker was not observed");
  let json=A.to_json [C.Durable,state C.Durable values] in
  check string "provider wait is an observed warning" "warning" (text "status" json);
  let op=member "operations" json |> Yojson.Safe.Util.to_list |> List.hd in
  check string "provider category survives" "provider_unavailable" (text "state" op);
  let waiting=member "last_cycle_waiting" op |> Yojson.Safe.Util.to_list |> List.hd in
  check string "original request survives" "original-request" (text "request_id" waiting);
  check bool "provider body stays out of public health" false
    (Astring.String.is_infix ~affix:"PRIVATE PROVIDER BODY" (Yojson.Safe.to_string json));
  check string "availability is not success" "not_proven_by_availability" (text "provider_execution" op);
  let live entry={empty with serving=[entry]} in
  (match C.select C.Durable (live {entry with package_id="unrelated"}) with
   | Error (C.Wrong_package {actual}) -> check string "package identity is checked" "unrelated" actual
   | Ok _ | Error (Unattached | Unready _ | Export_conflict _ | Manual_installation) ->
     fail "a same-name tool from another package was admitted");
  (match C.select C.Durable (live {entry with installation_id=None}) with
   | Error C.Manual_installation -> ()
   | Ok _ | Error (Unattached | Unready _ | Export_conflict _ | Wrong_package _) ->
     fail "manual attachment invented a declaration route");
  unavailable A.Declaration_not_applied
    (state C.Durable (observe ~mode:(A.Live (live {entry with configuration_revision=Some "old"})) [d]))

let () = run "Keeper Memory execution dependencies"
  ["configuration",[test_case "absent, off, admitted and live are distinct" `Quick test_absent_off_and_unobserved_are_distinct;
    test_case "real package binds admission and durable" `Quick test_actual_package_requires_both_routes;
    test_case "invalid configuration, deselection and rejected slots stay distinct" `Quick test_invalid_configuration_and_deselection_are_distinct;
    test_case "real manifest parse errors do not expose input or paths" `Quick test_real_manifest_parse_error_stays_in_authenticated_diagnostics];
   "runtime",[test_case "unready and conflicts are not absence" `Quick test_starting_failed_and_conflict_are_not_absent;
    test_case "provider observation preserves cause and privacy" `Quick test_serving_retains_provider_cause_without_leaking_body]]
