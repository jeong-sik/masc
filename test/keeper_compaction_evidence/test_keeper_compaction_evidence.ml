let evidence : Keeper_compaction_evidence.t =
  Keeper_compaction_evidence.create
    ~selected_runtime_id:"compact-runtime"
    ~before_checkpoint_bytes:4096
    ~after_checkpoint_bytes:1024
    ~before_message_count:12
    ~after_message_count:11
    ~summarized_message_count:6
    ~dropped_message_count:1
    ~before_tool_use_count:3
    ~after_tool_use_count:3
    ~before_tool_result_count:3
    ~after_tool_result_count:3
  |> Result.get_ok
;;

let canonical = Keeper_compaction_evidence.to_json evidence

let fields = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "canonical evidence must be an object"
;;

let replace name value json =
  `Assoc
    (List.map
       (fun (key, current) ->
          if String.equal key name then key, value else key, current)
       (fields json))
;;

let remove name json =
  `Assoc
    (List.filter
       (fun (key, _) -> not (String.equal key name))
       (fields json))
;;

let test_projection_and_roundtrip () =
  let expected =
    `Assoc
      [ "before_checkpoint_bytes", `Int 4096
      ; "after_checkpoint_bytes", `Int 1024
      ; "before_message_count", `Int 12
      ; "after_message_count", `Int 11
      ; "summarized_message_count", `Int 6
      ; "dropped_message_count", `Int 1
      ; "before_tool_use_count", `Int 3
      ; "after_tool_use_count", `Int 3
      ; "before_tool_result_count", `Int 3
      ; "after_tool_result_count", `Int 3
      ]
  in
  Alcotest.check
    (Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal)
    "exact projection"
    expected
    canonical;
  match
    Keeper_compaction_evidence.of_json
      ~selected_runtime_id:evidence.selected_runtime_id
      canonical
  with
  | Ok restored -> Alcotest.(check bool) "exact restore" true (restored = evidence)
  | Error _ -> Alcotest.fail "canonical evidence must decode"
;;

let test_runtime_identity_is_not_normalized () =
  let exact_runtime_id = "  exact.runtime  " in
  match
    Keeper_compaction_evidence.create
      ~selected_runtime_id:exact_runtime_id
      ~before_checkpoint_bytes:8
      ~after_checkpoint_bytes:4
      ~before_message_count:2
      ~after_message_count:1
      ~summarized_message_count:0
      ~dropped_message_count:1
      ~before_tool_use_count:0
      ~after_tool_use_count:0
      ~before_tool_result_count:0
      ~after_tool_result_count:0
  with
  | Error error ->
    Alcotest.failf
      "exact runtime identity rejected: %s"
      (Keeper_compaction_evidence.decode_error_to_string error)
  | Ok evidence ->
    Alcotest.(check string) "runtime identity remains exact" exact_runtime_id
      evidence.selected_runtime_id
;;

let test_rejections () =
  let open Keeper_compaction_evidence in
  let check label runtime_id expected json =
    match of_json ~selected_runtime_id:runtime_id json with
    | Error actual -> Alcotest.(check bool) label true (actual = expected)
    | Ok _ -> Alcotest.failf "%s: invalid evidence decoded" label
  in
  let no_messages =
    canonical
    |> replace "summarized_message_count" (`Int 0)
    |> replace "dropped_message_count" (`Int 0)
  in
  let duplicate =
    `Assoc (("after_message_count", `Int 11) :: fields canonical)
  in
  let impossible_accounting =
    replace "summarized_message_count" (`Int 999) canonical
  in
  let inexact_after = replace "after_message_count" (`Int 10) canonical in
  List.iter
    (fun (label, runtime_id, expected, json) ->
       check label runtime_id expected json)
    [ ( "negative"
      , evidence.selected_runtime_id
      , Invalid_field (Before_message_count, Negative_integer)
      , replace "before_message_count" (`Int (-1)) canonical )
    ; ( "not reduced"
      , evidence.selected_runtime_id
      , Invalid_transition (Checkpoint_bytes, 4096, 4096)
      , replace "after_checkpoint_bytes" (`Int 4096) canonical )
    ; "no messages", evidence.selected_runtime_id, No_messages_compacted, no_messages
    ; "blank runtime", "   ", Empty_selected_runtime_id, canonical
    ; ( "duplicate"
      , evidence.selected_runtime_id
      , Invalid_field (After_message_count, Duplicate)
      , duplicate )
    ; ( "unknown field"
      , evidence.selected_runtime_id
      , Unknown_field "retired_counter"
      , `Assoc (("retired_counter", `Int 1) :: fields canonical) )
    ; ( "missing field"
      , evidence.selected_runtime_id
      , Invalid_field (Before_tool_use_count, Missing)
      , remove "before_tool_use_count" canonical )
    ; ( "non-integer field"
      , evidence.selected_runtime_id
      , Invalid_field (Before_tool_result_count, Expected_integer)
      , replace "before_tool_result_count" (`String "3") canonical )
    ; ( "message count increase"
      , evidence.selected_runtime_id
      , Invalid_transition (Messages, 12, 13)
      , replace "after_message_count" (`Int 13) canonical )
    ; ( "tool use count increase"
      , evidence.selected_runtime_id
      , Invalid_transition (Tool_uses, 3, 4)
      , replace "after_tool_use_count" (`Int 4) canonical )
    ; ( "tool use count decrease"
      , evidence.selected_runtime_id
      , Invalid_transition (Tool_uses, 3, 2)
      , replace "after_tool_use_count" (`Int 2) canonical )
    ; ( "tool result count increase"
      , evidence.selected_runtime_id
      , Invalid_transition (Tool_results, 3, 4)
      , replace "after_tool_result_count" (`Int 4) canonical )
    ; ( "tool result count decrease"
      , evidence.selected_runtime_id
      , Invalid_transition (Tool_results, 3, 2)
      , replace "after_tool_result_count" (`Int 2) canonical )
    ; ( "impossible message accounting"
      , evidence.selected_runtime_id
      , Invalid_message_accounting
          { before_message_count = 12
          ; after_message_count = 11
          ; summarized_message_count = 999
          ; dropped_message_count = 1
          }
      , impossible_accounting )
    ; ( "inexact after count"
      , evidence.selected_runtime_id
      , Invalid_message_accounting
          { before_message_count = 12
          ; after_message_count = 10
          ; summarized_message_count = 6
          ; dropped_message_count = 1
          }
      , inexact_after )
    ]
;;

let test_legacy_pair_repair_field_is_rejected () =
  let open Keeper_compaction_evidence in
  let legacy =
    `Assoc
      (("pair_repair_dropped_message_count", `Int 0) :: fields canonical)
  in
  match
    of_json
      ~selected_runtime_id:evidence.selected_runtime_id
      legacy
  with
  | Error (Unknown_field "pair_repair_dropped_message_count") -> ()
  | Error error ->
    Alcotest.failf
      "unexpected legacy-field rejection: %s"
      (decode_error_to_string error)
  | Ok _ -> Alcotest.fail "legacy pair-repair field decoded"
;;

let () =
  Alcotest.run
    "keeper compaction evidence"
    [ ( "projection"
      , [ Alcotest.test_case
            "projection and roundtrip"
            `Quick
            test_projection_and_roundtrip
        ; Alcotest.test_case "closed rejections" `Quick test_rejections
        ; Alcotest.test_case "runtime identity is not normalized" `Quick
            test_runtime_identity_is_not_normalized
        ; Alcotest.test_case
            "legacy pair-repair field rejected"
            `Quick
            test_legacy_pair_repair_field_is_rejected
        ] )
    ]
