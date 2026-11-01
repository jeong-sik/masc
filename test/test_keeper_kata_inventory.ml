open Alcotest
module M = Masc.Keeper_sandbox_microvm
module B = Masc.Keeper_microvm_backend
module R = Masc.Keeper_sandbox_runtime
let base = "/fixture/owned"
let id c = String.make 64 c
let row ?(root=base) ?(keeper="alpha") ?(owner=Some "41002")
    ?(runtime=B.kata_containerd_shim) c =
  let labels =
    [ R.sandbox_component_label_key, R.sandbox_component_label_value
    ; R.sandbox_base_path_hash_label_key, R.base_path_hash root
    ; R.sandbox_keeper_label_key, keeper
    ; R.sandbox_kind_label_key, M.keeper_vm_container_kind
    ] @ (match owner with None -> [] | Some pid -> [R.sandbox_owner_pid_label_key, pid])
  in
  `Assoc [ "id", `String (id c); "name", `String ("vm-" ^ keeper);
           "image", `String "proof:local"; "status", `String "Up 2 minutes";
           "created_at", `String "2026-09-08T00:00:00Z"; "runtime", `String runtime;
           "labels", `Assoc (List.map (fun (k,v) -> k, `String v) labels) ]
let lines rows = String.concat "\n" (List.map Yojson.Safe.to_string rows)
let get = function Ok x -> x | Error e -> fail e
let alive pid = pid = 41001
let candidates raw = M.nerdctl_sweep_candidates_of_json_lines ~base_path:base ~is_pid_alive:alive raw

let test_status_inventory_is_scoped_and_not_prose_parsed () =
  let raw = lines [ row 'a'; row ~root:"/other" 'b'; row ~keeper:"beta" 'c';
                    row ~runtime:"io.containerd.runc.v2" 'd' ] in
  let result = M.nerdctl_live_containers_of_json_lines ~base_path:base ~keeper_name:"alpha" raw |> get in
  match result with
  | [container] ->
    check string "full id" (id 'a') container.R.id;
    check string "real nerdctl name" "vm-alpha" container.name;
    check string "display status retained" "Up 2 minutes" container.status;
    check bool "running not guessed from display prose" true (container.running = None)
  | _ -> fail "foreign base, keeper or non-Kata container leaked into status"

let test_only_known_dead_positive_owner_is_reaped () =
  let queried = ref [] in
  let raw = lines [row 'a'; row ~owner:(Some "41001") 'b'; row ~owner:None 'c';
    row ~owner:(Some "invalid") 'd'; row ~owner:(Some "0") 'e';
    row ~owner:(Some "-1") 'f'; row ~root:"/other" '1';
    row ~runtime:"io.containerd.runc.v2" '2'; row ~keeper:"" '3'] in
  let result = M.nerdctl_sweep_candidates_of_json_lines ~base_path:base
    ~is_pid_alive:(fun pid -> queried := pid :: !queried; alive pid) raw |> get in
  check (list string) "only dead owned Kata id" [id 'a'] (List.map (fun x -> x.M.container_id) result);
  check bool "invalid process groups never queried" true (List.for_all (fun p -> p > 0) !queried)

let test_malformed_inventory_refuses_whole_snapshot () =
  let replace key value = function
    | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
    | _ -> fail "fixture row not object"
  in
  List.iter (fun raw ->
    match candidates raw with Error _ -> () | Ok _ -> fail "malformed inventory accepted")
    [ lines [row 'a'] ^ "\nnot-json"
    ; lines [row 'a'; row 'a']
    ; lines [replace "labels" (`String "owner=41002") (row 'b')]
    ; lines [replace "id" (`String "--all") (row 'b')]
    ; lines [replace "runtime" `Null (row 'b')]
    ; lines [replace "labels" (`Assoc ["x",`String "a"; "x",`String "b"]) (row 'b')]
    ];
  check int "empty inventory is readable" 0 (List.length (candidates "\n" |> get))

let test_actual_sweep_routes_inventory_and_removal () =
  let seen = ref [] in
  let run_argv ~timeout_sec:_ argv =
    seen := argv :: !seen;
    match argv with
    | "nerdctl" :: "ps" :: _ -> Unix.WEXITED 0, lines [row 'a'; row ~owner:(Some "41001") 'b']
    | ["nerdctl"; "rm"; "--force"; target] when target = id 'a' -> Unix.WEXITED 0, ""
    | _ -> fail "unexpected or unsafe Kata sweep command"
  in
  let results = M.sweep_abandoned_guests ~base_path:base
    ~command_available:(String.equal "nerdctl") ~timeout_sec:1. ~is_pid_alive:alive ~run_argv in
  (match results with
   | [B.Nerdctl_kata, result] -> check (list string) "dead guest removed" [id 'a'] result.M.removed
   | _ -> fail "wrong swept backend");
  (match List.rev !seen with
   | ("nerdctl" :: "ps" :: "-a" :: "--no-trunc" :: "--format" :: [_template]) :: [_delete] -> ()
   | _ -> fail "inventory was not the explicit nerdctl template")

let test_bad_or_failed_inventory_never_removes () =
  List.iter (fun response ->
    let count = ref 0 in
    let run_argv ~timeout_sec:_ argv =
      incr count;
      match argv with "nerdctl" :: "ps" :: _ -> response | _ -> fail "removed from unreadable inventory" in
    ignore (M.sweep_abandoned_guests ~base_path:base ~command_available:(String.equal "nerdctl")
      ~timeout_sec:1. ~is_pid_alive:alive ~run_argv);
    check int "only inventory command executed" 1 !count)
    [Unix.WEXITED 0, lines [row 'a'] ^ "\nbroken"; Unix.WEXITED 1, "daemon failed"]

let test_name_observation_is_independent_of_scope_labels () =
  let observe = M.kata_name_observation_of_json_lines ~guest_name:"vm-alpha" in
  let expect observation raw =
    check bool "name observation" true (observe raw = observation) in
  let scoped = row 'a' in
  let foreign = row ~root:"/foreign" 'b' in
  let other_runtime = row ~runtime:"io.containerd.runc.v2" 'c' in
  let replace key value = function
    | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
    | _ -> fail "fixture row not object" in
  expect M.Kata_name_absent (lines [row ~keeper:"beta" 'd']);
  expect M.Kata_name_expected_runtime (lines [scoped]);
  expect M.Kata_name_expected_runtime (lines [foreign]);
  expect M.Kata_name_other_runtime (lines [other_runtime]);
  expect M.Kata_name_runtime_unreported (lines [replace "runtime" `Null foreign]);
  expect M.Kata_name_runtime_unreported (lines [replace "runtime" (`String "") foreign]);
  let without_runtime = match foreign with
    | `Assoc fields -> `Assoc (List.remove_assoc "runtime" fields)
    | _ -> fail "fixture row not object" in
  expect M.Kata_name_runtime_unreported (lines [without_runtime]);
  expect M.Kata_name_absent "";
  expect M.Kata_name_unavailable (lines [foreign; row 'e']);
  expect M.Kata_name_unavailable (lines [foreign] ^ "\nnot-json");
  expect M.Kata_name_unavailable
    {|{"name":"vm-alpha","name":"other","runtime":"io.containerd.kata.v2"}|};
  expect M.Kata_name_unavailable (lines [replace "name" `Null (row ~keeper:"beta" 'f')]);
  let listed raw = M.nerdctl_live_containers_of_json_lines ~base_path:base ~keeper_name:"alpha" raw |> get in
  check int "scoped guest still appears in existing inventory" 1 (List.length (listed (lines [scoped])));
  check int "same-runtime foreign labels remain outside existing inventory" 0 (List.length (listed (lines [foreign])));
  check int "other runtime remains outside existing inventory" 0 (List.length (listed (lines [other_runtime])))
;;

let test_name_observation_runs_only_listing_in_execution_context () =
  let module Name = Masc.Keeper_sandbox_container_name in
  let network_mode = Masc.Keeper_types_profile.Network_none in
  let name = Name.make (Name.Micro_vm_persistent
      {base_path=base; keeper_name="alpha"; network_mode}) |> Name.to_string in
  let called = ref 0 in
  let env = Masc.Env_keeper_scrub.filter_environment (Unix.environment ()) in
  let cwd = Config_dir_resolver.current_working_dir () in
  let response = ref (Ok (Unix.WEXITED 0, lines [`Assoc ["name", `String name; "runtime", `String "other"]])) in
  let run ~timeout_sec ~env ~cwd ~argv =
    incr called;
    check bool "timeout passed to provider" true (timeout_sec = 2.);
    check (array string) "execution environment" (Masc.Env_keeper_scrub.filter_environment (Unix.environment ())) env;
    check string "execution cwd" (Config_dir_resolver.current_working_dir ()) cwd;
    (match argv with
     | ["nerdctl"; "ps"; "-a"; "--no-trunc"; "--format"; _] -> ()
     | _ -> fail "name observation attempted a non-listing command");
    !response in
  let observe () = M.Kata_observation_for_testing.observe ~run ~env ~cwd ~base_path:base
      ~keeper_name:"alpha" ~network_mode ~timeout_sec:2. in
  check bool "other runtime visible" true (observe () = M.Kata_name_other_runtime);
  response := Ok (Unix.WEXITED 1, "");
  check bool "failed listing is not absence" true (observe () = M.Kata_name_unavailable);
  response := Error ();
  check bool "incomplete capture is not absence" true (observe () = M.Kata_name_unavailable);
  check int "only one listing per observation" 3 !called;
  List.iter (fun timeout_sec ->
    check bool "expired or invalid timeout is unavailable" true
      (M.Kata_observation_for_testing.observe ~run ~env ~cwd ~base_path:base
         ~keeper_name:"alpha" ~network_mode ~timeout_sec = M.Kata_name_unavailable))
    [0.; -1.; Float.nan];
  check int "expired name query never runs" 3 !called
;;

let test_inventory_refuses_invalid_timeout_before_spawning () =
  let seen = ref [] in
  let run ~timeout_sec argv =
    seen := timeout_sec :: !seen;
    match argv with
    | "nerdctl" :: "ps" :: _ -> Unix.WEXITED 0, lines [row 'a'; row 'b'], ""
    | "nerdctl" :: "inspect" :: _ -> Unix.WEXITED 0, "true", ""
    | _ -> fail "unexpected inventory command" in
  let observe timeout_sec = M.Kata_observation_for_testing.inventory ~run B.Nerdctl_kata
      ~base_path:base ~keeper_name:"alpha" ~timeout_sec in
  List.iter (fun timeout_sec ->
    match observe timeout_sec with Error _ -> () | Ok _ -> fail "invalid timeout was accepted")
    [0.; -1.; Float.nan];
  check int "invalid timeout never spawns" 0 (List.length !seen);
  check int "valid timeout inspects both rows" 2 (List.length (observe 1. |> get));
  check int "one list and two inspections" 3 (List.length !seen)
;;

let () = run "Kata labelled inventory"
  ["inventory", [test_case "scope and display state" `Quick test_status_inventory_is_scoped_and_not_prose_parsed;
    test_case "safe owner identity" `Quick test_only_known_dead_positive_owner_is_reaped;
    test_case "malformed snapshot refusal" `Quick test_malformed_inventory_refuses_whole_snapshot;
    test_case "real sweep command boundary" `Quick test_actual_sweep_routes_inventory_and_removal;
    test_case "failed inventory cannot delete" `Quick test_bad_or_failed_inventory_never_removes;
    test_case "name observed without ownership labels" `Quick test_name_observation_is_independent_of_scope_labels;
    test_case "name listing execution boundary" `Quick test_name_observation_runs_only_listing_in_execution_context;
    test_case "invalid inventory timeout" `Quick test_inventory_refuses_invalid_timeout_before_spawning]]
