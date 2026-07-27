(* RFC-0356: the replayed write must carry the approved payload, not a
   payload the model re-emits. These cases pin the reconstruction from a
   stored Gate input to the write tool arguments. *)

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let result_json =
  Alcotest.result json (Alcotest.testable Fmt.string String.equal)
;;

(* The pinned resource identity stays in the approved input and is
   deliberately absent from the reconstructed arguments: the write handler
   re-derives it, so a target replaced between approval and replay produces a
   different canonical input and the approval no longer matches. *)
let approved_content_input =
  `Assoc
    [ ( "effect"
      , `Assoc
          [ "operation", `String "atomic_replace_entry"
          ; ( "target_resource"
            , `Assoc [ "device", `Intlit "16777232"; "inode", `Intlit "94211" ]
            )
          ] )
    ; "requested_target", `String "/playground/executor/repos/masc/a.ml"
    ; "content", `String "let a = 1\n"
    ]
;;

let approved_edit_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "patch_then_atomic_replace_entry" ]
    ; "requested_target", `String "/playground/executor/repos/masc/b.ml"
    ; "content", `String ""
    ; "old_string", `String "let b = 1"
    ; "new_string", `String "let b = 2"
    ; "replace_all", `Bool true
    ]
;;

let test_content_write () =
  Alcotest.check
    result_json
    "content write keeps the approved target and payload"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/a.ml"
           ; "mode", `String "overwrite"
           ; "content", `String "let a = 1\n"
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_content_input)
;;

let test_edit_write () =
  Alcotest.check
    result_json
    "edit write carries old_string, new_string, and replace_all"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/b.ml"
           ; "mode", `String "patch"
           ; "content", `String ""
           ; "old_string", `String "let b = 1"
           ; "new_string", `String "let b = 2"
           ; "replace_all", `Bool true
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_edit_input)
;;

(* A content write must not acquire edit fields: reconstruction carries only
   what the approval contained, so replay cannot widen the approved effect. *)
let test_absent_fields_are_not_invented () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input approved_content_input
  with
  | Error detail -> Alcotest.fail detail
  | Ok (`Assoc fields) ->
    List.iter
      (fun name ->
         Alcotest.check
           Alcotest.bool
           (Printf.sprintf "%s absent" name)
           false
           (List.mem_assoc name fields))
      [ "old_string"; "new_string"; "replace_all" ]
  | Ok _ -> Alcotest.fail "reconstructed arguments are not an object"
;;

(* An approved append must not replay as an overwrite: the mode arg defaults
   to overwrite, so dropping it would destroy the file the operator approved
   appending to. *)
let approved_append_input =
  `Assoc
    [ "effect", `Assoc [ "operation", `String "append_pinned_resource" ]
    ; "requested_target", `String "/playground/executor/repos/masc/log.txt"
    ; "content", `String "one more line\n"
    ]
;;

let test_append_stays_append () =
  Alcotest.check
    result_json
    "append mode survives the round trip"
    (Ok
       (`Assoc
           [ "path", `String "/playground/executor/repos/masc/log.txt"
           ; "mode", `String "append"
           ; "content", `String "one more line\n"
           ]))
    (Masc.Keeper_gate_replay.write_args_of_gate_input approved_append_input)
;;

let test_unreproducible_effect_is_rejected () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input
      (`Assoc
          [ "effect", `Assoc [ "operation", `String "create_entry_exclusive" ]
          ; "requested_target", `String "/playground/executor/new.txt"
          ; "content", `String "x"
          ])
  with
  | Ok _ ->
    Alcotest.fail "an effect this module cannot reproduce must not replay"
  | Error _ -> ()
;;

let test_missing_target_is_rejected () =
  match
    Masc.Keeper_gate_replay.write_args_of_gate_input
      (`Assoc [ "content", `String "orphan" ])
  with
  | Ok _ -> Alcotest.fail "input without requested_target must not reconstruct"
  | Error _ -> ()
;;

let test_non_object_input_is_rejected () =
  match Masc.Keeper_gate_replay.write_args_of_gate_input (`String "opaque") with
  | Ok _ -> Alcotest.fail "non-object input must not reconstruct"
  | Error _ -> ()
;;

let test_network_read_request_keeps_exact_input () =
  let input =
    `Assoc
      [ "capability", `String "web_search"
      ; ( "input"
        , `Assoc
            [ "query", `String "OpenAI official product announcements"
            ; "limit", `Int 5
            ] )
      ]
  in
  match Masc.Keeper_gate_replay.network_read_request_of_gate_input input with
  | Ok (Masc.Keeper_gate_replay.Web_search actual) ->
    Alcotest.check
      json
      "stored WebSearch input is unchanged"
      (`Assoc
         [ "query", `String "OpenAI official product announcements"
         ; "limit", `Int 5
         ])
      actual
  | Ok (Masc.Keeper_gate_replay.Web_fetch _) ->
    Alcotest.fail "WebSearch decoded as WebFetch"
  | Error detail -> Alcotest.fail detail
;;

let test_network_read_request_rejects_unknown_capability () =
  match
    Masc.Keeper_gate_replay.network_read_request_of_gate_input
      (`Assoc
         [ "capability", `String "arbitrary_network_effect"
         ; "input", `Assoc []
         ])
  with
  | Ok _ -> Alcotest.fail "unknown network capability must not replay"
  | Error _ -> ()
;;

let test_applied_context_prevents_duplicate_call () =
  let context =
    Masc.Keeper_gate_replay.context_for_outcome
      ~approval_id:"appr-test"
      (Masc.Keeper_gate_replay.Applied "{\"status\":\"ok\"}")
    |> Option.value ~default:""
  in
  Alcotest.(check bool)
    "context says effect already executed"
    true
    (String_util.contains_substring
       context
       "has already executed; do not call it again");
  Alcotest.(check bool)
    "context labels replay output untrusted"
    true
    (String_util.contains_substring context "untrusted external data")
;;

let () =
  Alcotest.run
    "keeper_gate_replay"
    [ ( "write_args_of_gate_input"
      , [ Alcotest.test_case "content write" `Quick test_content_write
        ; Alcotest.test_case "edit write" `Quick test_edit_write
        ; Alcotest.test_case
            "absent fields stay absent"
            `Quick
            test_absent_fields_are_not_invented
        ; Alcotest.test_case "append stays append" `Quick test_append_stays_append
        ; Alcotest.test_case
            "unreproducible effect rejected"
            `Quick
            test_unreproducible_effect_is_rejected
        ; Alcotest.test_case
            "missing target rejected"
            `Quick
            test_missing_target_is_rejected
        ; Alcotest.test_case
            "non-object rejected"
            `Quick
            test_non_object_input_is_rejected
        ] )
    ; ( "network_read"
      , [ Alcotest.test_case
            "keeps exact WebSearch input"
            `Quick
            test_network_read_request_keeps_exact_input
        ; Alcotest.test_case
            "rejects unknown capability"
            `Quick
            test_network_read_request_rejects_unknown_capability
        ; Alcotest.test_case
            "applied context prevents duplicate call"
            `Quick
            test_applied_context_prevents_duplicate_call
        ] )
    ]
;;
