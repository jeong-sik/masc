(** Test keeper identity parsing — specifically the Result error paths
    introduced by the failwith→Result refactor (PR #6479). *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let minimal_keeper_json ~trace_id =
  `Assoc
    [ ("name", `String "alice")
    ; ("agent_name", `String "keeper-alice-agent")
    ; ("trace_id", `String trace_id)
    ; ("goal", `String "test")
    ]

let test_valid_trace_id () =
  match Masc_test_deps.meta_of_json_fixture (minimal_keeper_json ~trace_id:"alice-001") with
  | Ok meta ->
      check string "name" "alice" meta.name;
      check string "agent_name" "keeper-alice-agent" meta.agent_name
  | Error e -> fail ("expected Ok, got Error: " ^ e)

let test_explicit_keeper_name_is_not_nickname_canonicalized () =
  let json =
    `Assoc
      [ ("name", `String "personality-resync-test")
      ; ("agent_name", `String "personality-resync-test")
      ; ("trace_id", `String "personality-resync-test-001")
      ; ("goal", `String "test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
      check string "explicit keeper name"
        "personality-resync-test" meta.name
  | Error e -> fail ("expected Ok, got Error: " ^ e)

let test_removed_keeper_cascade_alias_rejected () =
  (* Removed route aliases must fail at the persisted JSON boundary instead
     of silently collapsing to the keeper route. *)
  let json =
    `Assoc
      [
        ("name", `String "alice");
        ("agent_name", `String "keeper-alice-agent");
        ("trace_id", `String "alice-001");
        ("goal", `String "test");
        ("cascade_name", `String "oas-keeper_unified");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error msg ->
      check bool "error mentions cascade_name" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "cascade_name") msg 0);
           true
         with
         | Not_found -> false)
  | Ok meta ->
      fail
        ("expected removed alias rejection, got "
         ^ Keeper_types.cascade_name_of_meta meta)

let test_unknown_bare_cascade_name_rejected () =
  (* Bare cascade names are no longer accepted. Operators must use
     canonical tier-group./tier./route. names. *)
  let json =
    `Assoc
      [
        ("name", `String "cheolsu");
        ("agent_name", `String "keeper-cheolsu-agent");
        ("trace_id", `String "cheolsu-001");
        ("goal", `String "test");
        ("cascade_name", `String "playground_experiment_xyz");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error msg ->
      check bool "error mentions canonical prefix" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "canonical cascade prefix")
                msg
                0);
           true
         with
         | Not_found -> false)
  | Ok meta ->
      fail
        ("expected bare cascade rejection, got "
         ^ Keeper_types.cascade_name_of_meta meta)

let test_missing_trace_id () =
  let json =
    `Assoc
      [ ("name", `String "bob")
      ; ("agent_name", `String "keeper-bob-agent")
      ; ("goal", `String "test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error msg ->
      check bool "error mentions trace_id"
        true
        (String.length msg > 0
         && (try ignore (Str.search_forward (Str.regexp_string "trace_id") msg 0); true
             with Not_found -> false))
  | Ok _ -> fail "expected Error for missing trace_id"

let test_empty_trace_id () =
  match Masc_test_deps.meta_of_json_fixture (minimal_keeper_json ~trace_id:"") with
  | Error msg ->
      check bool "error mentions missing trace_id"
        true
        (String.length msg > 0
         && (try ignore (Str.search_forward (Str.regexp_string "missing trace_id") msg 0); true
             with Not_found -> false))
  | Ok _ -> fail "expected Error for empty trace_id"

let test_invalid_trace_id () =
  match Masc_test_deps.meta_of_json_fixture (minimal_keeper_json ~trace_id:"..") with
  | Error msg ->
      check bool "error mentions invalid trace_id"
        true
        (String.length msg > 0
         && (try ignore (Str.search_forward (Str.regexp_string "invalid trace_id") msg 0); true
             with Not_found -> false))
  | Ok _ -> fail "expected Error for invalid trace_id '..'"

let () =
  run "keeper_identity_parse"
    [ ( "parse_keeper_identity"
      , [ test_case "valid trace_id" `Quick test_valid_trace_id
        ; test_case "explicit keeper name is not nickname-canonicalized" `Quick
            test_explicit_keeper_name_is_not_nickname_canonicalized
        ; test_case "removed keeper cascade alias rejected" `Quick
            test_removed_keeper_cascade_alias_rejected
        ; test_case "unknown bare cascade name rejected" `Quick
            test_unknown_bare_cascade_name_rejected
        ; test_case "missing trace_id field" `Quick test_missing_trace_id
        ; test_case "empty trace_id" `Quick test_empty_trace_id
        ; test_case "invalid trace_id (..)" `Quick test_invalid_trace_id
        ] )
    ]
