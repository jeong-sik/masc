(** Test keeper identity parsing — specifically the Result error paths
    introduced by the failwith→Result refactor (PR #6479). *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok

let minimal_keeper_json ~trace_id =
  `Assoc
    [ ("name", `String "alice")
    ; ("agent_name", `String "keeper-alice-agent")
    ; ("trace_id", `String trace_id)
    ]

let strict_meta_of_fields fields =
  Masc.Keeper_meta_json_parse.meta_of_json (`Assoc fields)

let test_valid_trace_id () =
  match Masc_test_deps.meta_of_json_fixture (minimal_keeper_json ~trace_id:"alice-001") with
  | Ok meta ->
      check string "name" "alice" meta.name;
      check string "agent_name" "keeper-alice-agent" meta.agent_name
  | Error e -> fail ("expected Ok, got Error: " ^ e)

let test_explicit_keeper_name_is_not_nickname_canonicalized () =
  let json =
    `Assoc
      [ ("name", `String "instruction-resync-test")
      ; (* keeper_meta_json_parse rejects an agent_name that is not
           Keeper_identity.keeper_agent_name of the keeper name. The point of
           this case is that [name] itself is not nickname-canonicalized, which
           the assertion below still checks. *)
        ("agent_name", `String "keeper-instruction-resync-test-agent")
      ; ("trace_id", `String "instruction-resync-test-001")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
      check string "explicit keeper name"
        "instruction-resync-test" meta.name
  | Error e -> fail ("expected Ok, got Error: " ^ e)

let test_missing_trace_id () =
  match
    strict_meta_of_fields
      [ ("name", `String "bob")
      ; ("agent_name", `String "keeper-bob-agent")
      ]
  with
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
      (* keeper_meta_json_parse:102 says "trace_id must not be empty"; the
         previous "missing trace_id" wording never appeared for this input. *)
      check bool "error names the empty trace_id"
        true
        (String.length msg > 0
         && (try ignore (Str.search_forward (Str.regexp_string "trace_id must not be empty") msg 0); true
             with Not_found -> false))
  | Ok _ -> fail "expected Error for empty trace_id"

let test_invalid_trace_id () =
  match Masc_test_deps.meta_of_json_fixture (minimal_keeper_json ~trace_id:"..") with
  | Error msg ->
      (* keeper_meta_json_parse:106 and :369 both say "trace_id is invalid";
         the previous assertion looked for the reversed "invalid trace_id". *)
      check bool "error names the invalid trace_id"
        true
        (String.length msg > 0
         && (try ignore (Str.search_forward (Str.regexp_string "trace_id is invalid") msg 0); true
             with Not_found -> false))
  | Ok _ -> fail "expected Error for invalid trace_id '..'"

let () =
  run "keeper_identity_parse"
    [ ( "parse_keeper_identity"
      , [ test_case "valid trace_id" `Quick test_valid_trace_id
        ; test_case "explicit keeper name is not nickname-canonicalized" `Quick
            test_explicit_keeper_name_is_not_nickname_canonicalized
        ; test_case "missing trace_id field" `Quick test_missing_trace_id
        ; test_case "empty trace_id" `Quick test_empty_trace_id
        ; test_case "invalid trace_id (..)" `Quick test_invalid_trace_id
        ] )
    ]
;;
