open Alcotest
open Masc
open Masc.Keeper_types_profile

let meta profile =
  match Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String "observed-keeper"
                  ; "trace_id", `String "trace-observed-keeper" ]) with
  | Ok meta -> { meta with sandbox_profile = profile; microvm_backend = None }
  | Error error -> fail error
;;

let observe profile ?containers_override () =
  let base_path = Filename.temp_dir "masc-sandbox-observation-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
      Keeper_sandbox_control.live_status_json
        ~include_preflight:false ~include_repository_checkouts:false
        ?containers_override ~config:(Workspace.default_config base_path)
        ~meta:(meta profile) ~timeout_sec:1. ~verbose:false ())
;;

let field key = Yojson.Safe.Util.member key

let test_failed_inventory_is_unknown () =
  let json = observe Docker ~containers_override:(Error "inventory unavailable") () in
  check bool "failed Docker inventory cannot establish a mode" true
    (field "effective_mode" json = `Null);
  check string "original failure survives" "inventory unavailable"
    (field "container_error" json |> Yojson.Safe.Util.to_string)
;;

let test_unresolved_microvm_is_unknown () =
  let json = observe Micro_vm () in
  check bool "unresolved microVM backend is not a stopped guest" true
    (field "effective_mode" json = `Null);
  check bool "the failed inventory remains visible" true
    (field "container_error" json <> `Null);
  check string "unresolved backend has a typed diagnostic" "microvm_backend_unresolved"
    (field "container_error_code" json |> Yojson.Safe.Util.to_string);
  let base_path = Filename.temp_dir "masc-kata-name-unresolved-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let name = Keeper_sandbox_control.kata_name_observation_json
        ~config:(Workspace.default_config base_path) ~meta:(meta Micro_vm) ~timeout_sec:1. in
    check string "unresolved runtime does not mean inapplicable" "unavailable"
      (field "state" name |> Yojson.Safe.Util.to_string))
;;

let test_successful_inventory_keeps_mode () =
  let json = observe Docker ~containers_override:(Ok []) () in
  check bool "successful empty inventory has no error" true
    (field "container_error" json = `Null);
  check bool "successful inventory retains its effective mode" true
    (field "effective_mode" json <> `Null)
;;

let test_image_issue_code_preserves_original_diagnostic () =
  let base_path = Filename.temp_dir "masc-image-issue-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let meta = { (meta Docker) with sandbox_image = None } in
    let json = Keeper_sandbox_control.live_status_json
        ~include_preflight:false ~include_repository_checkouts:false
        ~containers_override:(Ok []) ~config:(Workspace.default_config base_path)
        ~meta ~timeout_sec:1. ~verbose:false () in
    check string "missing image has typed code" "not_declared"
      (field "configured_image_unresolved_code" json |> Yojson.Safe.Util.to_string);
    check bool "original diagnostic remains available" true
      (field "configured_image_unresolved" json <> `Null))
;;

let test_guest_size_code_preserves_original_diagnostic () =
  let check_bad_value key =
    let previous = Config_boot_overrides.get_opt key in
    Fun.protect
      ~finally:(fun () -> match previous with
        | Some value -> Config_boot_overrides.set key value
        | None -> Config_boot_overrides.clear key)
      (fun () ->
        Config_boot_overrides.set key "invalid-fixture";
        let json = observe Micro_vm () |> field "resource_config" in
        check string "unresolved guest size has a typed code" "guest_size_unresolved"
          (field "guest_size_error_code" json |> Yojson.Safe.Util.to_string);
        check bool "original size diagnostic remains available" true
          (match field "guest_size_error" json with `String _ -> true | _ -> false)) in
  List.iter check_bad_value ["MASC_KEEPER_MICROVM_MEMORY"; "MASC_KEEPER_MICROVM_CPUS"]
;;

let test_kata_environment_and_name_request () =
  let module C = Keeper_sandbox_control in
  let module M = Keeper_sandbox_microvm in
  let base_path = Filename.temp_dir "masc-kata-environment-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let meta = { (meta Micro_vm) with microvm_backend = Some Keeper_microvm_backend.Nerdctl_kata } in
    let base = [| "PATH=/usr/bin:/bin"; "HOME=/home/fixture";
                  "UNRELATED_SECRET=must-not-be-forwarded" |] in
    let calls = ref 0 in
    let run ~timeout_sec ~env ~cwd ~argv =
      incr calls;
      check bool "unrelated credential is not forwarded" false
        (Array.exists (String.starts_with ~prefix:"UNRELATED_SECRET=") env);
      check string "turn probe cwd" "/workspace" cwd;
      check bool "timeout is passed" true (timeout_sec = 1.);
      (match argv with
       | ["nerdctl"; "ps"; "-a"; "--no-trunc"; "--format"; _] -> ()
       | _ -> fail "unexpected name observation request");
      Ok (Unix.WEXITED 0, "") in
    let observe ambient cwd = C.Kata_status_for_testing.observe_name
        ~run ~config ~meta ~ambient ~cwd ~timeout_sec:1. in
    let inventory_calls = ref 0 in
    let inventory ~execution_context ~config:observed_config ~meta:observed_meta ~timeout_sec =
      incr inventory_calls;
      check bool "inventory keeps the workspace" true (observed_config == config);
      check bool "inventory keeps the keeper" true (observed_meta == meta);
      check bool "inventory timeout is passed" true (timeout_sec = 1.);
      (match execution_context with
       | Some (env, cwd) ->
         check string "inventory uses the turn cwd" "/workspace" cwd;
         check bool "inventory does not forward a credential" false
           (Array.exists (String.starts_with ~prefix:"UNRELATED_SECRET=") env);
         check bool "inventory does not forward the host containerd selector" false
           (Array.exists (String.starts_with ~prefix:"CONTAINERD_ADDRESS=") env)
       | None -> fail "Kata inventory omitted the scrubbed environment");
      Ok [] in
    let observe_inventory ambient cwd = C.Kata_status_for_testing.observe_inventory
        ~run:inventory ~config ~meta ~ambient ~cwd ~timeout_sec:1. in
    let alignment ambient cwd = C.Kata_status_for_testing.environment_alignment ~ambient ~cwd in
    check bool "default selectors align" true (alignment base "/workspace" = C.Kata_selectors_match);
    check bool "aligned turn name query ran" true
      (Option.map snd (observe base "/workspace") = Some M.Kata_name_absent);
    check bool "aligned inventory dispatched" true (observe_inventory base "/workspace" = Ok []);
    let custom = Array.append base [|"XDG_CONFIG_HOME=/home/fixture/config"|] in
    check bool "preserved nondefault config aligns" true
      (alignment custom "/workspace" = C.Kata_selectors_match);
    check bool "preserved config name query ran" true
      (Option.map snd (observe custom "/workspace") = Some M.Kata_name_absent);
    check bool "preserved config inventory dispatched" true
      (observe_inventory custom "/workspace" = Ok []);
    let sensitive = ["CONTAINERD_ADDRESS"; "CONTAINERD_NAMESPACE"; "NERDCTL_TOML";
      "XDG_RUNTIME_DIR"; "CONTAINERD_SNAPSHOTTER"; "ROOTLESSKIT_STATE_DIR";
      "ROOTLESSKIT_PARENT_EUID"; "ROOTLESSKIT_PARENT_EGID"] in
    List.iter (fun key ->
      let ambient = Array.append base [|key ^ "=nondefault"|] in
      check bool "differing host selector" true (alignment ambient "/workspace" = C.Kata_selectors_differ);
      check bool "different host selector retains scrubbed inventory" true
        (observe_inventory ambient "/workspace" = Ok []);
      check bool "different context produced no name verdict" true
        (Option.map snd (observe ambient "/workspace") = Some M.Kata_name_unavailable)) sensitive;
    List.iter (fun (ambient, cwd, executable) ->
      check bool "uncertain selector context" true (alignment ambient cwd = C.Kata_selectors_unavailable);
      check bool "inventory requires an unambiguous explicit execution context" executable
        (Result.is_ok (observe_inventory ambient cwd));
      check bool "unknown context produced no name verdict" true
        (Option.map snd (observe ambient cwd) = Some M.Kata_name_unavailable))
      [base, "relative", false;
       [|"PATH=/usr/bin:/bin:."; "HOME=/home/fixture"|], "/workspace", true;
       [|"PATH=/usr/bin:/bin:"; "HOME=/home/fixture"|], "/workspace", true;
       [|"PATH=/bin"|], "/workspace", true;
       Array.append base [|"PATH=/different"|], "/workspace", false;
       Array.append base [|"malformed"|], "/workspace", true];
    check int "only the two aligned name requests reached the CLI" 2 !calls;
    check int "only usable scrubbed inventories reached the observer" 14 !inventory_calls)
;;

let test_kata_log_inventory_and_stream_use_one_execution_context () =
  let module C = Keeper_sandbox_control in
  let base_path = Filename.temp_dir "masc-kata-log-context-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let meta = { (meta Micro_vm) with microvm_backend = Some Keeper_microvm_backend.Nerdctl_kata } in
    let backend = C.Micro_vm_logs Keeper_microvm_backend.Nerdctl_kata in
    let row : Keeper_sandbox_runtime.live_container =
      { id = "fixture-id"; name = "fixture-name"; image = "fixture-image"; status = "running"
      ; running = Some true; created_at = None; keeper_name = Some "observed-keeper"
      ; container_kind = None; network_label = None; owner_pid = None; started_at = None
      ; ttl_sec = None; cpus = None; memory_bytes = None; hostname = None
      ; ipv4_address = None; ipv6_address = None; gateway = None } in
    let seen_context = ref None in
    let listing_calls = ref 0 and log_calls = ref 0 in
    let list_containers ~env ~cwd ~backend:actual_backend ~config:actual_config
        ~keeper_name ~timeout_sec =
      incr listing_calls;
      check bool "listing keeps the backend" true (actual_backend = backend);
      check bool "listing keeps the workspace" true (actual_config == config);
      check string "listing keeps the Keeper" "observed-keeper" keeper_name;
      check bool "listing passes timeout" true (timeout_sec = 1.);
      (match env, cwd with
       | Some env, Some "/workspace" ->
         check bool "unrelated credential withheld from listing" false
           (Array.exists (String.starts_with ~prefix:"UNRELATED_SECRET=") env);
         check bool "host containerd namespace withheld from listing" false
           (Array.exists (String.starts_with ~prefix:"CONTAINERD_NAMESPACE=") env)
       | _ -> fail "Kata listing lacks explicit execution context");
      seen_context := Some (env, cwd);
      Ok [row] in
    let read_logs ~env ~cwd ~timeout_sec ~argv =
      incr log_calls;
      check bool "log uses the exact captured listing environment and cwd" true
        (!seen_context = Some (env, cwd));
      check bool "log passes timeout" true (timeout_sec = 1.);
      check (list string) "logs use the observed instance id"
        ["nerdctl"; "logs"; "--tail"; "12"; "fixture-id"] argv;
      Unix.WEXITED 0, "opaque-stdout", "opaque-stderr" in
    let collect ambient cwd = C.Sandbox_logs_for_testing.collect ~list_containers ~read_logs
        ~config ~meta ~backend ~ambient ~cwd ~timeout_sec:1. ~tail:12 in
    let check_observed ambient expected = match collect ambient "/workspace" with
      | Error _ -> fail "valid explicit context did not read logs"
      | Ok json ->
        check string "selector comparison is a separate observation" expected
          (field "kata_host_environment_alignment" json |> Yojson.Safe.Util.to_string);
        let rows = field "instances" json |> Yojson.Safe.Util.to_list in
        let first = List.hd rows in
        check string "stdout preserved in the response" "opaque-stdout"
          (field "stdout" first |> Yojson.Safe.Util.to_string);
        check string "stderr preserved in the response" "opaque-stderr"
          (field "stderr" first |> Yojson.Safe.Util.to_string) in
    let base = [|"PATH=/usr/bin:/bin"; "HOME=/home/fixture";
                 "UNRELATED_SECRET=must-not-be-forwarded"|] in
    check_observed base "selectors_match";
    check_observed (Array.append base [|"CONTAINERD_NAMESPACE=other"|]) "selectors_differ";
    check_observed [|"PATH=/usr/bin:/bin:."; "HOME=/home/fixture"|] "selectors_unavailable";
    check_observed [|"PATH=/bin"|] "selectors_unavailable";
    List.iter (fun (ambient, cwd) ->
      match collect ambient cwd with
      | Error (C.Sandbox_logs_backend_failed _) -> ()
      | Error (C.Sandbox_logs_meta_read_failed _ | C.Sandbox_logs_keeper_not_found) | Ok _ ->
        fail "invalid explicit execution context did not fail")
      [base, "relative"; Array.append base [|"PATH=/different"|], "/workspace"];
    check int "invalid context did not list" 4 !listing_calls;
    check int "invalid context did not read logs" 4 !log_calls;
    let failed_listing ~env:_ ~cwd:_ ~backend:_ ~config:_ ~keeper_name:_ ~timeout_sec:_ =
      Error "listing unavailable" in
    (match C.Sandbox_logs_for_testing.collect ~list_containers:failed_listing ~read_logs
        ~config ~meta ~backend ~ambient:base ~cwd:"/workspace" ~timeout_sec:1. ~tail:12 with
     | Error (C.Sandbox_logs_backend_failed _) -> ()
     | Error (C.Sandbox_logs_meta_read_failed _ | C.Sandbox_logs_keeper_not_found) | Ok _ ->
       fail "failed inventory did not fail the log read");
    check int "failed inventory does not start a log command" 4 !log_calls;
    let failed_log ~env ~cwd ~timeout_sec ~argv =
      ignore (read_logs ~env ~cwd ~timeout_sec ~argv : Unix.process_status * string * string);
      Unix.WEXITED 1, "partial-stdout", "partial-stderr" in
    (match C.Sandbox_logs_for_testing.collect ~list_containers ~read_logs:failed_log
        ~config ~meta ~backend ~ambient:base ~cwd:"/workspace" ~timeout_sec:1. ~tail:12 with
     | Error _ -> fail "failed log command lost its observation"
     | Ok json ->
       let row = field "instances" json |> Yojson.Safe.Util.to_list |> List.hd in
       check bool "failed log command carries an error" true (field "error" row <> `Null);
       check string "partial stdout preserved" "partial-stdout"
         (field "stdout" row |> Yojson.Safe.Util.to_string);
       check string "partial stderr preserved" "partial-stderr"
         (field "stderr" row |> Yojson.Safe.Util.to_string));
    let inherited_calls = ref 0 in
    let inherited_listing ~env ~cwd ~backend:_ ~config:_ ~keeper_name:_ ~timeout_sec:_ =
      check bool "other backends keep inherited environment and cwd" true
        (env = None && cwd = None);
      Ok [row] in
    let inherited_read ~env ~cwd ~timeout_sec:_ ~argv:_ =
      check bool "other backend log reads keep inherited environment and cwd" true
        (env = None && cwd = None);
      incr inherited_calls;
      Unix.WEXITED 0, "", "" in
    List.iter (fun backend ->
      match C.Sandbox_logs_for_testing.collect ~list_containers:inherited_listing
          ~read_logs:inherited_read ~config ~meta ~backend ~ambient:base ~cwd:"relative"
          ~timeout_sec:1. ~tail:12 with
      | Ok _ -> () | Error _ -> fail "non-Kata backend was refused by the Kata context")
      [C.Docker_logs; C.Micro_vm_logs Keeper_microvm_backend.Apple_container;
       C.Micro_vm_logs Keeper_microvm_backend.Microsandbox];
    check int "all other backends retained their log read" 3 !inherited_calls)
;;

let test_kata_name_observation_does_not_claim_start_or_ownership () =
  let module M = Keeper_sandbox_microvm in
  let project observation scoped_name_seen has_containers =
    Keeper_sandbox_control.Kata_status_for_testing.project
      ~observation ~scoped_name_seen ~has_containers
      ~initial_effective_mode:(Some "microvm_vm_not_running")
      ~initial_why_no_container:(Some "a guest is created on first execution") in
  List.iter (fun observation ->
    let mode, reason = project observation (Some false) false in
    check bool "unowned or unknown name cannot establish mode" true (mode = None);
    check bool "unowned or unknown name cannot promise a first start" true
      (reason <> Some "a guest is created on first execution"))
    [M.Kata_name_expected_runtime; M.Kata_name_other_runtime;
     M.Kata_name_runtime_unreported; M.Kata_name_unavailable];
  let mode, _ = project M.Kata_name_expected_runtime (Some true) true in
  check bool "same name in separate observations does not establish current mode" true (mode = None);
  let mode, reason = project M.Kata_name_absent (Some false) false in
  check bool "an empty listing is not a current mode" true (mode = None);
  check bool "empty listing does not promise a future start" true
    (reason <> Some "a guest is created on first execution");
  let mode, _ = project M.Kata_name_absent (Some true) true in
  check bool "different-time conflicting observations do not establish mode" true (mode = None)
;;

let () =
  run "keeper_sandbox_observation"
    [ "inventory", [ test_case "failed inventory is unknown" `Quick test_failed_inventory_is_unknown
                   ; test_case "unresolved microVM is unknown" `Quick test_unresolved_microvm_is_unknown
                   ; test_case "successful inventory keeps mode" `Quick test_successful_inventory_keeps_mode
                   ; test_case "image issue code retains diagnostic" `Quick test_image_issue_code_preserves_original_diagnostic
                   ; test_case "guest size code retains diagnostic" `Quick test_guest_size_code_preserves_original_diagnostic
                   ; test_case "Kata environment and name request" `Quick test_kata_environment_and_name_request
                   ; test_case "Kata log requests keep one execution context" `Quick
                       test_kata_log_inventory_and_stream_use_one_execution_context
                   ; test_case "Kata name observation" `Quick test_kata_name_observation_does_not_claim_start_or_ownership ] ]
;;
