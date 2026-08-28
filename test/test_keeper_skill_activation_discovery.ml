open Alcotest
open Masc

module Discovery = Keeper_skill_activation_discovery
module Ledger = Keeper_skill_activation_ledger

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_workspace operation =
  let root = Filename.temp_file "skill-activation-discovery-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> operation root (Workspace.default_config root))
;;

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let source_id =
  match Skill_source_config.source_id_of_string "workspace" with
  | Ok value -> value
  | Error detail -> fail detail
;;

let package_id value =
  match Skill_reference.package_id_of_directory value with
  | Ok value -> value
  | Error _ -> fail "invalid package fixture"
;;

let revision character =
  match Skill_reference.content_revision_of_string (String.make 64 character) with
  | Ok value -> value
  | Error _ -> fail "invalid revision fixture"
;;

let snapshot_revision =
  match Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'f') with
  | Ok value -> value
  | Error _ -> fail "invalid snapshot revision fixture"
;;

let reference ?(package = "review") ?(name = "review") character =
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(revision character)
;;

let activation ~trace ~tool_use_id ~activated_at reference =
  match
    Ledger.make_activation
      ~identity:reference.Skill_reference.identity
      ~content_revision:reference.content_revision
      ~snapshot_revision
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace)
           ~absolute_turn:1)
      ~runtime_id:"test.runtime"
      ~skill_tool_use_id:tool_use_id
      ~agent_core_turn:0
      ~invocation:
        (Ledger.Instruction_invocation
           { origin = Ledger.Session_instruction
           ; served_content =
               Ledger.Skill_body
                 { bytes = 4
                 ; sha256 =
                     Digestif.SHA256.(digest_string "BODY" |> to_hex)
                 }
           })
      ~activated_at
  with
  | Ok activation -> activation
  | Error _ -> fail "activation fixture was rejected"
;;

let create_session config trace =
  let path =
    Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace)
  in
  Unix.mkdir path 0o700
;;

let record config trace activation =
  match Ledger.record ~config ~trace_id:trace activation with
  | Ok _ -> ()
  | Error error -> fail (Ledger.store_error_to_string error)
;;

let ledger_gap_details gaps =
  List.filter_map
    (function
      | Discovery.Ledger_unreadable { trace_id; cause } ->
        Some
          (Keeper_id.Trace_id.to_string trace_id
           ^ ": "
           ^ Ledger.store_error_to_string cause)
      | _ -> None)
    gaps
;;

let test_missing_store_is_empty_and_read_only () =
  with_workspace @@ fun _root config ->
  let path = Keeper_fs.session_store_path config in
  check bool "trace store starts absent" false (Sys.file_exists path);
  let result = Discovery.discover config (reference 'a') in
  check bool "discovery does not create trace store" false (Sys.file_exists path);
  check int "no sessions inspected" 0 result.sessions_inspected;
  check int "no ledgers loaded" 0 result.ledgers_loaded;
  (match result.scope with
   | Discovery.Complete_retained_trace_snapshot -> ()
   | _ -> fail "missing retained store was not treated as an empty store");
  match result.latest with
  | Discovery.Not_observed -> ()
  | _ -> fail "missing retained store invented activation evidence"
;;

let test_discovers_historical_trace_and_filters_exact_reference () =
  with_workspace @@ fun _root config ->
  let expected = reference 'a' in
  let unrelated = reference ~package:"other" ~name:"other" 'b' in
  let old_trace = trace_id "trace-old" in
  let new_trace = trace_id "trace-new" in
  create_session config old_trace;
  create_session config new_trace;
  record
    config
    old_trace
    (activation
       ~trace:old_trace
       ~tool_use_id:"call-old"
       ~activated_at:"2026-08-29T00:00:00Z"
       expected);
  record
    config
    new_trace
    (activation
       ~trace:new_trace
       ~tool_use_id:"call-new"
       ~activated_at:"2026-08-29T01:00:00Z"
       expected);
  record
    config
    new_trace
    (activation
       ~trace:new_trace
       ~tool_use_id:"call-unrelated"
       ~activated_at:"2026-08-29T02:00:00Z"
       unrelated);
  let old_lock =
    Keeper_fs.keeper_session_dir config "trace-old" ^ ".checkpoint.lock"
  in
  let new_lock =
    Keeper_fs.keeper_session_dir config "trace-new" ^ ".checkpoint.lock"
  in
  List.iter
    (fun path -> if Sys.file_exists path then Unix.unlink path)
    [ old_lock; new_lock ];
  let result = Discovery.discover config expected in
  check bool "old trace lock was not recreated" false (Sys.file_exists old_lock);
  check bool "new trace lock was not recreated" false (Sys.file_exists new_lock);
  check int "every retained session inspected" 2 result.sessions_inspected;
  if result.ledgers_loaded <> 2
  then fail (String.concat "\n" (ledger_gap_details result.gaps));
  check int "no discovery gaps" 0 (List.length result.gaps);
  match result.latest with
  | Discovery.Most_recent_observed evidence ->
    check
      string
      "latest exact reference trace"
      "trace-new"
      (Keeper_id.Trace_id.to_string evidence.trace_id);
    check
      string
      "latest exact invocation"
      "call-new"
      evidence.activation.skill_tool_use_id
  | Discovery.Not_observed -> fail "historical activation was not discovered"
  | Discovery.Most_recent_observed_timestamp_tie _ ->
    fail "distinct timestamps became a tie"
;;

let test_equal_cross_trace_timestamp_is_not_arbitrarily_ordered () =
  with_workspace @@ fun _root config ->
  let expected = reference 'a' in
  let first_trace = trace_id "trace-a" in
  let second_trace = trace_id "trace-b" in
  List.iter (create_session config) [ first_trace; second_trace ];
  List.iter
    (fun (trace, tool_use_id) ->
       record
         config
         trace
         (activation
            ~trace
            ~tool_use_id
            ~activated_at:"2026-08-29T00:00:00Z"
            expected))
    [ first_trace, "call-a"; second_trace, "call-b" ];
  match (Discovery.discover config expected).latest with
  | Discovery.Most_recent_observed_timestamp_tie evidence ->
    check int "both equal-time traces remain visible" 2 (List.length evidence)
  | Discovery.Not_observed -> fail "equal-time activations disappeared"
  | Discovery.Most_recent_observed _ ->
    fail "equal-time cross-trace evidence was guessed"
;;

let test_invalid_and_symlink_trace_entries_are_structured_gaps () =
  with_workspace @@ fun root config ->
  let valid_trace = trace_id "trace-valid" in
  create_session config valid_trace;
  let store = Keeper_fs.session_store_path config in
  Unix.mkdir (Filename.concat store "invalid trace") 0o700;
  Unix.symlink root (Filename.concat store "trace-symlink");
  Fs_compat.save_file (Filename.concat store "trace-file") "not-a-session";
  let result = Discovery.discover config (reference 'a') in
  (match result.scope with
   | Discovery.Incomplete_retained_trace_snapshot -> ()
   | _ -> fail "unsafe retained entries did not mark coverage incomplete");
  check
    bool
    "invalid trace directory surfaced"
    true
    (List.exists
       (function Discovery.Invalid_trace_directory _ -> true | _ -> false)
       result.gaps);
  check
    bool
    "trace-shaped symlink surfaced"
    true
    (List.exists
       (function Discovery.Symlink_trace_entry _ -> true | _ -> false)
       result.gaps);
  check
    bool
    "trace-shaped regular file surfaced"
    true
    (List.exists
       (function Discovery.Trace_entry_not_directory _ -> true | _ -> false)
       result.gaps)
;;

let test_unreadable_ledger_keeps_partial_coverage_explicit () =
  with_workspace @@ fun _root config ->
  let trace = trace_id "trace-corrupt" in
  create_session config trace;
  let ledger_path =
    Filename.concat
      (Keeper_fs.keeper_session_dir config "trace-corrupt")
      "skill-activations.json"
  in
  Fs_compat.save_file ledger_path "not-json";
  let result = Discovery.discover config (reference 'a') in
  check int "corrupt session was inspected" 1 result.sessions_inspected;
  check int "corrupt ledger was not counted as loaded" 0 result.ledgers_loaded;
  (match result.scope with
   | Discovery.Incomplete_retained_trace_snapshot -> ()
   | _ -> fail "corrupt activation ledger did not mark coverage incomplete");
  match result.gaps with
  | [ Discovery.Ledger_unreadable { trace_id; _ } ] ->
    check
      string
      "unreadable ledger keeps typed trace"
      "trace-corrupt"
      (Keeper_id.Trace_id.to_string trace_id)
  | _ -> fail "corrupt ledger did not produce one structured gap"
;;

let test_revision_change_during_discovery_is_not_complete () =
  with_workspace @@ fun _root config ->
  let expected = reference 'a' in
  let trace = trace_id "trace-changing" in
  create_session config trace;
  record
    config
    trace
    (activation
       ~trace
       ~tool_use_id:"call-before"
       ~activated_at:"2026-08-29T00:00:00Z"
       expected);
  let result =
    Discovery.For_testing.discover
      ~after_first_pass:(fun () ->
        record
          config
          trace
          (activation
             ~trace
             ~tool_use_id:"call-during"
             ~activated_at:"2026-08-29T01:00:00Z"
             expected))
      config
      expected
  in
  (match result.scope with
   | Discovery.Incomplete_retained_trace_snapshot -> ()
   | _ -> fail "a changing ledger was reported as a complete snapshot");
  check
    bool
    "changed trace is explicit"
    true
    (List.exists
       (function
         | Discovery.Ledger_changed_during_discovery changed ->
           Keeper_id.Trace_id.equal trace changed
         | _ -> false)
       result.gaps)
;;

let test_trace_root_replacement_is_not_complete () =
  with_workspace @@ fun _root config ->
  let expected = reference 'a' in
  let trace = trace_id "trace-root-swap" in
  create_session config trace;
  record
    config
    trace
    (activation
       ~trace
       ~tool_use_id:"call-before-root-swap"
       ~activated_at:"2026-08-29T00:00:00Z"
       expected);
  let store = Keeper_fs.session_store_path config in
  let displaced = store ^ "-displaced" in
  let result =
    Discovery.For_testing.discover
      ~after_first_pass:(fun () ->
        Unix.rename store displaced;
        Unix.mkdir store 0o700)
      config
      expected
  in
  (match result.scope with
   | Discovery.Incomplete_retained_trace_snapshot -> ()
   | _ -> fail "a replaced trace root was reported as a complete snapshot");
  check
    bool
    "trace root identity change is explicit"
    true
    (List.exists
       (function Discovery.Trace_root_changed_during_discovery -> true | _ -> false)
       result.gaps);
  match result.latest with
  | Discovery.Not_observed -> ()
  | _ -> fail "evidence from a replaced trace root was exposed"
;;

let () =
  run
    "keeper Skill activation discovery"
    [ ( "retained trace authority"
      , [ test_case "missing store stays absent" `Quick
            test_missing_store_is_empty_and_read_only
        ; test_case "historical exact reference is discovered" `Quick
            test_discovers_historical_trace_and_filters_exact_reference
        ; test_case "cross-trace timestamp tie stays explicit" `Quick
            test_equal_cross_trace_timestamp_is_not_arbitrarily_ordered
        ; test_case "unsafe entries make coverage incomplete" `Quick
            test_invalid_and_symlink_trace_entries_are_structured_gaps
        ; test_case "unreadable ledger keeps partial coverage" `Quick
            test_unreadable_ledger_keeps_partial_coverage_explicit
        ; test_case "concurrent revision change is explicit" `Quick
            test_revision_change_during_discovery_is_not_complete
        ; test_case "trace root replacement is explicit" `Quick
            test_trace_root_replacement_is_not_complete
        ] )
    ]
;;
