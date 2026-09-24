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
let apple_inventory = ["container";"list";"-a";"--format";"json"], Ok "[]"
(* The one property-list reply both builder questions read: [build.rosetta]
   for the VM's start, [kernel.binaryPath] for the kernel its builds boot. *)
let apple_properties ?(kernel="opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug") ~rosetta () =
  ["container";"system";"property";"list";"--format";"json"],
  Ok (Printf.sprintf {|{"build":{"cpus":2,"memory":"2048mb","rosetta":%b},"container":{"cpus":4},"kernel":{"binaryPath":"%s"}}|}
        rosetta kernel)
let apple_build ~rosetta = apple_properties ~rosetta ()
let rosetta_receipt = ["pkgutil";"--pkg-info";"com.apple.pkg.RosettaUpdateAuto"]
let apple_ready = [apple_inventory; rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n"
  ; apple_properties ~rosetta:true ()]
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
    probe mac apple_ready S.Apple_container] in
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
let contents = "# preserve this comment\n[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"masc-sandbox:general\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n"
let selected = function Ok value -> value | Error e -> fail e
let test_staging () =
  let selection = S.selection_of_contents ~path:"imp.toml" ~contents
    ~profile:(Some Keeper_sandbox_config.Micro_vm)
    ~microvm_backend:(Some Masc.Keeper_microvm_backend.Apple_container)
    ~network_mode:None |> selected in
  check bool "preserve existing network decision" true (selection.network_mode=N.Network_inherit);
  let staged = S.stage_contents ~path:"imp.toml" ~contents selection |> selected in
  check bool "comment preserved" true (String.starts_with ~prefix:"# preserve this comment" staged);
  let reparsed = S.selection_of_contents ~path:"imp.toml" ~contents:staged
    ~profile:None ~microvm_backend:None ~network_mode:None |> selected in
  check bool "backend roundtrip" true (reparsed.backend=S.Apple_container);
  let invalid = S.selection_of_contents ~path:"imp.toml" ~contents
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
let microvm_without_backend = "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"microvm\"\nsandbox_image = \"masc-sandbox:general\"\nnetwork_mode = \"inherit\"\ninstructions = \"Respond to the operator.\"\n"
(* F107. A microvm declaration that names no backend is refused by the
   selection itself; on origin/main it silently became Apple Container on
   macOS 26 arm64 while every other host was refused, so the written TOML on a
   Mac never showed the choice. The wizard reaches Apple Container only through
   the catalog row's setup_args, which name the backend outright. *)
let test_no_host_default_backend () =
  let implicit = S.selection_of_contents ~path:"imp.toml" ~contents:microvm_without_backend
    ~profile:None ~microvm_backend:None ~network_mode:None in
  check bool "unnamed microvm backend refused without a host default" true (Result.is_error implicit);
  let explicit = S.selection_of_contents ~path:"imp.toml" ~contents:microvm_without_backend
    ~profile:None ~microvm_backend:(Some Masc.Keeper_microvm_backend.Apple_container) ~network_mode:None |> selected in
  check bool "named backend accepted" true (explicit.backend = S.Apple_container);
  let staged = S.stage_contents ~path:"imp.toml" ~contents:microvm_without_backend explicit |> selected in
  let reparsed = S.selection_of_contents ~path:"imp.toml" ~contents:staged
    ~profile:None ~microvm_backend:None ~network_mode:None |> selected in
  check bool "staged TOML names the backend on its own" true (reparsed.backend = S.Apple_container);
  let catalog = S.catalog_json ~host:mac ~configured:None [probe mac apple_ready S.Apple_container] in
  let row = Yojson.Safe.Util.member "candidates" catalog |> Yojson.Safe.Util.to_list |> List.hd in
  let setup_args = Yojson.Safe.Util.member "setup_args" row |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string in
  check (list string) "recommended row pre-fills the backend for setup"
    ["--sandbox-profile"; "microvm"; "--microvm-backend"; "apple_container"] setup_args
let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (mkdir_p (Filename.dirname dir); Sys.mkdir dir 0o700)
let with_workspace f =
  let base_path = Filename.temp_file "masc-sandbox-declaration-" "" in
  Sys.remove base_path; Sys.mkdir base_path 0o700;
  let path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:"imp" in
  let rec remove_tree entry =
    if Sys.is_directory entry then (Array.iter (fun child -> remove_tree (Filename.concat entry child)) (Sys.readdir entry);
      Sys.rmdir entry) else Sys.remove entry in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f ~base_path ~path)
(* F030. inspect's configuration_error used to be one of two constant
   sentences, so an operator could not tell a missing file from a permission
   error, nor a broken TOML from a microvm profile without a backend. The
   declaration now reports a closed kind plus the underlying reason, and the
   JSON carries both. *)
let test_declaration_reasons () =
  with_workspace (fun ~base_path ~path ->
    let unreadable = match S.declaration ~base_path with
      | Ok _ -> fail "missing imp.toml produced a selection" | Error error -> error in
    check bool "missing file is unreadable" true (unreadable.kind = S.Declaration_unreadable);
    check bool "OS message names the file" true
      (let open String in length unreadable.detail > length path
        && starts_with ~prefix:path unreadable.detail);
    (match S.configuration_error_json unreadable with
     | `Assoc fields ->
       check bool "kind serialized" true (List.assoc_opt "kind" fields = Some (`String "declaration_unreadable"));
       check bool "detail serialized" true (List.assoc_opt "detail" fields = Some (`String unreadable.detail))
     | _ -> fail "configuration_error is not an object");
    mkdir_p (Filename.dirname path);
    Out_channel.with_open_text path (fun out -> output_string out microvm_without_backend);
    let invalid = match S.declaration ~base_path with
      | Ok _ -> fail "backend-less microvm declaration produced a selection" | Error error -> error in
    check bool "parsed but unselectable is invalid" true (invalid.kind = S.Declaration_invalid);
    let expected = match S.selection_of_contents ~path ~contents:microvm_without_backend
        ~profile:None ~microvm_backend:None ~network_mode:None with
      | Error reason -> reason | Ok _ -> fail "fixture unexpectedly selectable" in
    check string "detail is the selection reason" expected invalid.detail;
    Out_channel.with_open_text path (fun out -> output_string out contents);
    check bool "readable docker declaration selects" true
      (match S.declaration ~base_path with Ok selection -> selection.backend = S.Docker | Error _ -> false))
(* Apple Container answers as a running service on a Mac without Rosetta, and
   then cannot start the VM it builds images in: that VM uses Rosetta unless
   [build] rosetta = false. Measured 2026-09-15 on a colleague's Mac: setup
   called the service ready and failed while preparing imp's image. The
   fixture answers only the commands a case names, so a command the probe was
   not supposed to run reads as missing and fails the case. *)
let test_an_apple_builder_that_cannot_start_is_not_ready () =
  let asked = ref [] in
  let recording responses argv = asked := argv :: !asked; run_fixture responses argv in
  let state responses =
    asked := [];
    (S.probe ~host:mac ~run:(recording responses) ~require_rootless:false ~require_userns:false
       S.Apple_container).state in
  let no_rosetta = rosetta_receipt, Error S.Command_failed in
  check bool "with Rosetta installed the builder is ready" true
    (state apple_ready = S.Service_ready);
  check bool "and its property list was read once, for the kernel" true
    (List.mem ["container";"system";"property";"list";"--format";"json"] !asked);
  check bool "without Rosetta, a builder set not to use it is ready" true
    (state [apple_inventory; no_rosetta; apple_build ~rosetta:false] = S.Service_ready);
  let needs_rosetta = [apple_inventory; no_rosetta; apple_build ~rosetta:true] in
  check bool "without Rosetta, a builder that uses it is a missing prerequisite" true
    (match state needs_rosetta with S.Missing_prerequisite _ -> true | _ -> false);
  List.iter (fun unread -> check bool "a setting that cannot be read is Apple's default, which uses Rosetta" true
    (match state (apple_inventory :: no_rosetta :: unread) with S.Missing_prerequisite _ -> true | _ -> false))
    [[]; [["container";"system";"property";"list";"--format";"json"], Ok {|{"build":{}}|}];
     [["container";"system";"property";"list";"--format";"json"], Ok "not json"]];
  check bool "no receipt tool is neither ready nor missing" true
    (match state [apple_inventory] with S.Probe_failed _ -> true | _ -> false);
  check bool "the CLI's answer: a service that answered and needs Rosetta" true
    (S.apple_container_needs_rosetta ~run:(run_fixture needs_rosetta));
  check bool "a stopped service is not a Rosetta question, whatever Rosetta says" false
    (S.apple_container_needs_rosetta
       ~run:(run_fixture [["container";"list";"-a";"--format";"json"], Error S.Command_failed; no_rosetta]));
  check bool "an absent service is not one either" false
    (S.apple_container_needs_rosetta ~run:(run_fixture [no_rosetta]));
  check bool "a Mac whose builder needs Rosetta is not steered to Apple Container" true
    (S.recommend ~host:mac ~configured:None
       [probe mac needs_rosetta S.Apple_container; probe mac (docker []) S.Docker] = Some S.Docker)

(* The same service with Rosetta settled but no default kernel configured:
   the VM starts, and the first [container build] dies asking for one. The
   property list carries the configured kernel as [kernel.binaryPath]; every
   shape that names none -- an empty object, an empty path, the field absent
   -- reads as unconfigured. Measured 2026-09-17 on a fresh Mac. *)
let test_an_apple_builder_without_a_default_kernel_is_not_ready () =
  let state responses =
    (probe mac responses S.Apple_container).state in
  let no_kernel ~rosetta = ["container";"system";"property";"list";"--format";"json"],
    Ok (Printf.sprintf {|{"build":{"rosetta":%b},"kernel":{}}|} rosetta) in
  check bool "a builder that starts but boots no kernel is a missing prerequisite" true
    (match state [apple_inventory; rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n";
                  no_kernel ~rosetta:false] with
     | S.Missing_prerequisite reason -> String.equal reason S.kernel_missing_reason
     | _ -> false);
  List.iter (fun unreadable ->
      check bool "a kernel that cannot be read is not configured" true
        (match state [apple_inventory; rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n";
                      unreadable] with
         | S.Missing_prerequisite _ -> true | _ -> false))
    [ ["container";"system";"property";"list";"--format";"json"], Ok {|{"build":{"rosetta":false}}|}
    ; ["container";"system";"property";"list";"--format";"json"],
      Ok {|{"build":{"rosetta":false},"kernel":{"binaryPath":""}}|}
    ; ["container";"system";"property";"list";"--format";"json"], Ok "not json" ];
  check bool "the CLI's answer: a service that answered and boots no kernel" true
    (S.apple_container_needs_default_kernel
       ~run:(run_fixture [apple_inventory; rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n";
                          no_kernel ~rosetta:false]));
  check bool "a stopped service is not a kernel question" false
    (S.apple_container_needs_default_kernel
       ~run:(run_fixture [["container";"list";"-a";"--format";"json"], Error S.Command_failed;
                          no_kernel ~rosetta:false]));
  check bool "a Mac that boots no kernel is not steered to Apple Container" true
    (S.recommend ~host:mac ~configured:None
       [probe mac [apple_inventory; rosetta_receipt, Ok "package-id: com.apple.pkg.RosettaUpdateAuto\n";
                   no_kernel ~rosetta:false] S.Apple_container;
        probe mac (docker []) S.Docker] = Some S.Docker)
let () = run "sandbox readiness" ["selection",[
  test_case "real service reply, not CLI presence" `Quick test_service_not_presence;
  test_case "catalog selection boundary" `Quick test_catalog_selection_boundary;
  test_case "hardening requirements" `Quick test_hardening;
  test_case "OS recommendation and configured preference" `Quick test_recommendation;
  test_case "a builder without a default kernel" `Quick test_an_apple_builder_without_a_default_kernel_is_not_ready;
  test_case "Kata prerequisites" `Quick test_kata_prerequisites;
  test_case "stale setup cannot overwrite newer selection" `Quick test_commit_conflict;
  test_case "validated staged selection preserves decisions" `Quick test_staging;
  test_case "no host default for a microvm backend" `Quick test_no_host_default_backend;
  test_case "declaration errors carry kind and reason" `Quick test_declaration_reasons;
  test_case "an Apple builder that cannot start is not ready" `Quick
    test_an_apple_builder_that_cannot_start_is_not_ready]]
