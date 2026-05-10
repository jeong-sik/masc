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

let test_legacy_keeper_cascade_alias_preserved_raw () =
  (* Parse should preserve the raw cascade_name as declared in JSON so the
     dashboard can surface config drift between the declared value and its
     canonicalized resolution.  Legacy aliases (e.g. "oas-keeper_unified")
     still resolve to the canonical at point-of-use via
     [Keeper_cascade_profile.canonicalize]. *)
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
  | Ok meta ->
      check string "legacy alias preserved raw"
        "oas-keeper_unified" (Keeper_types.cascade_name_of_meta meta);
      check string "legacy alias canonicalizes to default"
        Keeper_config.default_cascade_name
        (Keeper_cascade_profile.canonicalize
           (Keeper_types.cascade_name_of_meta meta))
  | Error e -> fail ("expected Ok, got Error: " ^ e)

let test_unknown_cascade_name_preserved_raw () =
  (* Genuinely unknown user-declared cascade names (typos, personal
     playground profiles, vendor drift) must survive parse so the
     dashboard [canonical] column can show the mismatch.  Prior
     behaviour silently collapsed them to "keeper_unified", masking
     config drift. *)
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
  | Ok meta ->
      check string "raw user-declared cascade preserved"
        "playground_experiment_xyz" (Keeper_types.cascade_name_of_meta meta);
      (* Point-of-use canonicalize still maps unknown → default. *)
      check string "unknown canonicalizes to default"
        Keeper_config.default_cascade_name
        (Keeper_cascade_profile.canonicalize
           (Keeper_types.cascade_name_of_meta meta))
  | Error e -> fail ("expected Ok, got Error: " ^ e)

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
        ; test_case "legacy keeper cascade alias preserved raw" `Quick
            test_legacy_keeper_cascade_alias_preserved_raw
        ; test_case "unknown cascade name preserved raw" `Quick
            test_unknown_cascade_name_preserved_raw
        ; test_case "missing trace_id field" `Quick test_missing_trace_id
        ; test_case "empty trace_id" `Quick test_empty_trace_id
        ; test_case "invalid trace_id (..)" `Quick test_invalid_trace_id
        ] )
    ]
