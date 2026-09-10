open Alcotest
module S = Masc.Sandbox_readiness
module N = Keeper_types_profile_sandbox
let linux = S.Linux S.X64
let mac = S.Macos {architecture=S.Arm64; major=26}
let run_fixture responses argv = match List.assoc_opt argv responses with
  | Some reply -> reply | None -> Error S.Missing_command
let docker security = [ ["docker";"info";"--format";"{{json .}}"],
  Ok (Yojson.Safe.to_string (`Assoc ["OSType",`String "linux";
    "SecurityOptions",`List (List.map (fun s -> `String s) security)])) ]
let probe ?(rootless=false) ?(userns=false) host responses backend =
  S.probe ~host ~run:(run_fixture responses) ~require_rootless:rootless ~require_userns:userns backend
let test_service_not_presence () =
  let missing = probe linux [] S.Docker in
  check bool "missing command classified" true
    (match missing.state with S.Missing_prerequisite _ -> true | _ -> false);
  let stopped = probe linux [["docker";"info";"--format";"{{json .}}"], Error S.Command_failed] S.Docker in
  check bool "stopped daemon refused" true
    (match stopped.state with S.Probe_failed _ -> true | _ -> false);
  let windows = probe linux [["docker";"info";"--format";"{{json .}}"], Ok {|{"OSType":"windows","SecurityOptions":[]}|}] S.Docker in
  check bool "wrong engine refused" true
    (match windows.state with S.Probe_failed _ -> true | _ -> false);
  let malformed = probe linux [["docker";"info";"--format";"{{json .}}"], Ok "linux"] S.Docker in
  check bool "invalid JSON refused" true
    (match malformed.state with S.Probe_failed _ -> true | _ -> false);
  let healthy = probe linux (docker []) S.Docker in
  check bool "service ready" true (healthy.state = S.Service_ready);
  check bool "no guest execution claimed" true (healthy.guest_verification = S.Not_run)
let test_catalog_selection_boundary () =
  let rows = [probe mac (docker []) S.Docker; probe mac [] S.Apple_container] in
  let catalog = S.catalog_json ~host:mac ~configured:None rows in
  let selected_id = Yojson.Safe.Util.member "recommended" catalog |> Yojson.Safe.Util.to_string in
  check bool "serialized recommendation resolves to real backend" true
    (S.backend_of_id selected_id = Some S.Docker);
  List.iter (fun id -> check bool "unknown or host fallback request rejected" true
      (S.backend_of_id id = None)) ["local"; "host"; "docker;sh"; ""];
  let candidates = Yojson.Safe.Util.member "candidates" catalog |> Yojson.Safe.Util.to_list in
  List.iter (fun row -> check bool "catalog does not advertise executed guests" true
    (Yojson.Safe.Util.member "guest_verification" row = `String "not_run")) candidates
let test_hardening () =
  check bool "required rootless absent" true
    (match (probe ~rootless:true linux (docker []) S.Docker).state with
     | S.Unsupported_capability _ -> true | _ -> false);
  check bool "required userns absent" true
    (match (probe ~userns:true linux (docker ["name=rootless"]) S.Docker).state with
     | S.Unsupported_capability _ -> true | _ -> false);
  check bool "both guarantees reported" true
    ((probe ~rootless:true ~userns:true linux (docker ["name=rootless";"name=userns"]) S.Docker).state = S.Service_ready)
let test_recommendation () =
  let rows = [probe mac (docker []) S.Docker;
    probe mac [["container";"list";"-a";"--format";"json"],Ok "[]"] S.Apple_container] in
  check bool "new supported Mac recommends Apple" true
    (S.recommend ~host:mac ~configured:None rows = Some S.Apple_container);
  check bool "existing healthy Docker preserved" true
    (S.recommend ~host:mac ~configured:(Some S.Docker) rows = Some S.Docker);
  List.iter (fun host ->
    let rows = List.map (probe host (docker [])) S.all in
    check bool "named platform recommends Docker" true
      (S.recommend ~host ~configured:None rows = Some S.Docker))
    [S.Linux S.Arm64; S.Linux S.X64; S.Macos {architecture=S.X64;major=26};
     S.Macos {architecture=S.Arm64;major=25}];
  check bool "no healthy candidate means no recommendation" true
    (S.recommend ~host:mac ~configured:None [probe mac [] S.Docker] = None);
  let msb = probe linux [] S.Microsandbox in
  check bool "msb is unsupported even before executable discovery" true
    (match msb.state with S.Unsupported_capability _ -> true | _ -> false)
let test_kata_prerequisites () =
  let info = ["nerdctl";"info";"--format";"{{json .}}"], Ok {|{"OSType":"linux"}|} in
  check bool "containerd alone is insufficient" true
    ((probe linux [info] S.Nerdctl_kata).state <> S.Service_ready);
  check bool "Kata host check required" true
    ((probe linux [info; ["kata-runtime";"check";"--no-network-checks"],Ok ""] S.Nerdctl_kata).state = S.Service_ready)
let contents = "# preserve this comment\n[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n"
let selected = function Ok value -> value | Error e -> fail e
let test_staging () =
  let selection = S.selection_of_contents ~host:mac ~path:"imp.toml" ~contents
    ~profile:(Some Keeper_sandbox_config.Micro_vm)
    ~microvm_backend:(Some Masc.Keeper_microvm_backend.Apple_container)
    ~network_mode:None |> selected in
  check bool "preserve existing network decision" true (selection.network_mode=N.Network_inherit);
  let staged = S.stage_contents ~path:"imp.toml" ~contents selection |> selected in
  check bool "comment preserved" true (String.starts_with ~prefix:"# preserve this comment" staged);
  let reparsed = S.selection_of_contents ~host:mac ~path:"imp.toml" ~contents:staged
    ~profile:None ~microvm_backend:None ~network_mode:None |> selected in
  check bool "backend roundtrip" true (reparsed.backend=S.Apple_container);
  let invalid = S.selection_of_contents ~host:linux ~path:"imp.toml" ~contents
    ~profile:None ~microvm_backend:None ~network_mode:(Some N.Network_policy) in
  check bool "unsupported network rejected before write" true (Result.is_error invalid)
let test_commit_conflict () =
  Eio_main.run (fun _ ->
    let path = Filename.temp_file "masc-sandbox-selection-" ".toml" in
    Fun.protect ~finally:(fun () -> Sys.remove path; if Sys.file_exists (path ^ ".lock") then Sys.remove (path ^ ".lock"))
      (fun () ->
        Out_channel.with_open_text path (fun out -> output_string out contents);
        let edited = contents ^ "# another editor\n" in
        Out_channel.with_open_text path (fun out -> output_string out edited);
        let result = S.commit_staged ~path ~original:contents ~staged:(contents ^ "# setup\n") in
        check bool "concurrent edit refused" true (Result.is_error result);
        check string "other editor bytes preserved" edited
          (In_channel.with_open_text path In_channel.input_all)))
let () = run "sandbox readiness" ["selection",[
  test_case "real service reply, not CLI presence" `Quick test_service_not_presence;
  test_case "catalog selection boundary" `Quick test_catalog_selection_boundary;
  test_case "hardening requirements" `Quick test_hardening;
  test_case "OS recommendation and configured preference" `Quick test_recommendation;
  test_case "Kata prerequisites" `Quick test_kata_prerequisites;
  test_case "stale setup cannot overwrite newer selection" `Quick test_commit_conflict;
  test_case "validated staged selection preserves decisions" `Quick test_staging]]
