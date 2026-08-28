open Alcotest
open Masc

module Owner = Keeper_skill_activation_owner

let with_workspace operation =
  let root = Filename.temp_dir "skill-activation-owner-" "" in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () -> operation config)
;;

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let meta ~name ~current_trace ~trace_history =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String current_trace
         ; "trace_history", `List (List.map (fun value -> `String value) trace_history)
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let write_meta config meta =
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let write_manifest config ~keeper_name ~trace_id =
  let path =
    Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let row =
    Keeper_runtime_manifest.make
      ~keeper_name
      ~trace_id
      ~event:Keeper_runtime_manifest.Turn_started
      ()
  in
  Fs_compat.save_file path (Yojson.Safe.to_string (Keeper_runtime_manifest.to_json row) ^ "\n")
;;

let known label expected_keeper expected_source result =
  match result.Owner.owner with
  | Owner.Known claim ->
    check
      string
      (label ^ " keeper")
      expected_keeper
      (Keeper_id.Keeper_name.to_string claim.keeper_name);
    check bool (label ^ " source") true (claim.source = expected_source)
  | Owner.Not_claimed_in_retained_catalog -> fail (label ^ " owner was absent")
  | Owner.Conflicting _ -> fail (label ^ " owner was ambiguous")
  | Owner.Incomplete _ -> fail (label ^ " owner coverage was incomplete")
  | Owner.Catalog_unavailable ->
    let detail =
      result.gaps
      |> List.filter_map (function
           | Owner.Keeper_catalog_unavailable detail -> Some detail
           | _ -> None)
      |> String.concat "\n"
    in
    fail (label ^ " owner catalog was unavailable: " ^ detail)
;;

let test_exact_owner_sources_and_conflict () =
  with_workspace @@ fun config ->
  write_meta
    config
    (meta ~name:"current" ~current_trace:"trace-current" ~trace_history:[]);
  write_meta
    config
    (meta
       ~name:"history"
       ~current_trace:"trace-history-new"
       ~trace_history:[ "trace-history" ]);
  write_meta
    config
    (meta ~name:"manifest" ~current_trace:"trace-manifest-new" ~trace_history:[]);
  write_meta
    config
    (meta ~name:"conflict-a" ~current_trace:"trace-a" ~trace_history:[]);
  write_meta
    config
    (meta ~name:"conflict-b" ~current_trace:"trace-b" ~trace_history:[]);
  write_manifest config ~keeper_name:"manifest" ~trace_id:"trace-manifest";
  write_manifest config ~keeper_name:"conflict-a" ~trace_id:"trace-conflict";
  write_manifest config ~keeper_name:"conflict-b" ~trace_id:"trace-conflict";
  let current = Owner.resolve config (trace_id "trace-current") in
  let history = Owner.resolve config (trace_id "trace-history") in
  let manifest = Owner.resolve config (trace_id "trace-manifest") in
  known "current" "current" Owner.Current_meta current;
  known "history" "history" Owner.Trace_history history;
  known "manifest" "manifest" Owner.Runtime_manifest manifest;
  check int "current has no gaps" 0 (List.length current.gaps);
  check int "history has no gaps" 0 (List.length history.gaps);
  check int "manifest has no gaps" 0 (List.length manifest.gaps);
  (match (Owner.resolve config (trace_id "trace-unknown")).owner with
   | Owner.Not_claimed_in_retained_catalog -> ()
   | _ -> fail "unknown trace invented an owner");
  match (Owner.resolve config (trace_id "trace-conflict")).owner with
  | Owner.Conflicting claims ->
    check
      (list string)
      "both conflicting keepers remain visible"
      [ "conflict-a"; "conflict-b" ]
      (List.map
         (fun claim -> Keeper_id.Keeper_name.to_string claim.Owner.keeper_name)
         claims)
  | Owner.Known _ -> fail "conflicting owners were arbitrated"
  | Owner.Not_claimed_in_retained_catalog -> fail "conflicting owners disappeared"
  | Owner.Incomplete _ -> fail "conflicting owner coverage was incomplete"
  | Owner.Catalog_unavailable -> fail "conflicting owner catalog was unavailable"
;;

let test_nonregular_manifest_is_a_gap_not_an_owner () =
  with_workspace @@ fun config ->
  write_meta
    config
    (meta ~name:"unsafe" ~current_trace:"trace-other" ~trace_history:[]);
  let path =
    Keeper_runtime_manifest.path_for_trace
      config
      ~keeper_name:"unsafe"
      ~trace_id:"trace-unsafe"
  in
  Fs_compat.mkdir_p path;
  let result = Owner.resolve config (trace_id "trace-unsafe") in
  (match result.owner with
   | Owner.Incomplete [] -> ()
   | _ -> fail "nonregular runtime manifest was not incomplete");
  check
    bool
    "nonregular manifest is explicit"
    true
    (List.exists
       (function Owner.Runtime_manifest_entry_unreadable _ -> true | _ -> false)
       result.gaps)
;;

let test_runtime_only_keeper_and_manifest_validation () =
  with_workspace @@ fun config ->
  write_manifest config ~keeper_name:"runtime-only" ~trace_id:"trace-runtime-only";
  known
    "runtime-only"
    "runtime-only"
    Owner.Runtime_manifest
    (Owner.resolve config (trace_id "trace-runtime-only"));
  let invalid_path =
    Keeper_runtime_manifest.path_for_trace
      config
      ~keeper_name:"runtime-only"
      ~trace_id:"trace-invalid"
  in
  Fs_compat.save_file invalid_path "{}\n";
  let invalid = Owner.resolve config (trace_id "trace-invalid") in
  (match invalid.owner with
   | Owner.Incomplete [] -> ()
   | _ -> fail "invalid manifest was accepted as an owner claim");
  check
    bool
    "invalid manifest row is explicit"
    true
    (List.exists
       (function Owner.Runtime_manifest_entry_unreadable _ -> true | _ -> false)
       invalid.gaps)
;;

let test_metadata_name_mismatch_is_incomplete () =
  with_workspace @@ fun config ->
  let copied = meta ~name:"actual" ~current_trace:"trace-copied" ~trace_history:[] in
  let path = Keeper_types_profile.keeper_meta_path config "catalog" in
  Fs_compat.save_file
    path
    (Keeper_meta_json.meta_to_json copied |> Yojson.Safe.to_string);
  let result = Owner.resolve config (trace_id "trace-copied") in
  (match result.owner with
   | Owner.Incomplete [] -> ()
   | _ -> fail "copied metadata payload invented a catalog owner");
  check
    bool
    "metadata name mismatch is explicit"
    true
    (List.exists
       (function Owner.Keeper_meta_name_mismatch _ -> true | _ -> false)
       result.gaps)
;;

let test_catalog_change_during_resolution_is_incomplete () =
  with_workspace @@ fun config ->
  write_manifest config ~keeper_name:"first" ~trace_id:"trace-changing-owner";
  let result =
    Owner.For_testing.resolve
      ~after_claims:(fun () ->
        write_manifest
          config
          ~keeper_name:"second"
          ~trace_id:"trace-changing-owner")
      config
      (trace_id "trace-changing-owner")
  in
  (match result.owner with
   | Owner.Incomplete claims ->
     check
       (list string)
       "both pass observations stay visible"
       [ "first"; "second" ]
       (List.map
          (fun claim -> Keeper_id.Keeper_name.to_string claim.Owner.keeper_name)
          claims)
   | _ -> fail "changing owner catalog was reported as complete");
  check
    bool
    "catalog change is explicit"
    true
    (List.exists
       (function Owner.Keeper_catalog_changed_during_resolution -> true | _ -> false)
       result.gaps)
;;

let test_missing_keeper_store_stays_absent () =
  let root = Filename.temp_dir "skill-activation-owner-empty-" "" in
  let config = Workspace.default_config root in
  let keeper_store = Workspace.keepers_runtime_dir config in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
       check bool "keeper store starts absent" false (Sys.file_exists keeper_store);
       let result = Owner.resolve config (trace_id "trace-unknown") in
       check bool "owner lookup stays read-only" false (Sys.file_exists keeper_store);
       match result.owner with
       | Owner.Not_claimed_in_retained_catalog -> ()
       | _ -> fail "empty retained catalog invented an owner")
;;

let () =
  run
    "keeper Skill activation owner"
    [ ( "retained owner projection"
      , [ test_case "exact sources and conflict remain typed" `Quick
            test_exact_owner_sources_and_conflict
        ; test_case "nonregular manifest is not an owner" `Quick
            test_nonregular_manifest_is_a_gap_not_an_owner
        ; test_case "runtime-only owner validates manifest rows" `Quick
            test_runtime_only_keeper_and_manifest_validation
        ; test_case "metadata name mismatch is incomplete" `Quick
            test_metadata_name_mismatch_is_incomplete
        ; test_case "catalog change is incomplete" `Quick
            test_catalog_change_during_resolution_is_incomplete
        ; test_case "missing Keeper store stays absent" `Quick
            test_missing_keeper_store_stays_absent
        ] )
    ]
;;
