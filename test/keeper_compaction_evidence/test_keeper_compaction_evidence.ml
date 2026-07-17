let evidence : Keeper_compaction_evidence.t =
  Keeper_compaction_evidence.create
    ~selected_runtime_id:(Some "compact-runtime")
    ~before_checkpoint_bytes:4096
    ~after_checkpoint_bytes:1024
    ~before_message_count:12
    ~after_message_count:6
    ~summarized_message_count:6
    ~dropped_message_count:1
    ~pair_repair_dropped_message_count:0
    ~before_tool_use_count:3
    ~after_tool_use_count:1
    ~before_tool_result_count:3
    ~after_tool_result_count:1
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
      ; "after_message_count", `Int 6
      ; "summarized_message_count", `Int 6
      ; "dropped_message_count", `Int 1
      ; "pair_repair_dropped_message_count", `Int 0
      ; "before_tool_use_count", `Int 3
      ; "after_tool_use_count", `Int 1
      ; "before_tool_result_count", `Int 3
      ; "after_tool_result_count", `Int 1
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
    `Assoc (("after_message_count", `Int 6) :: fields canonical)
  in
  let impossible_accounting =
    replace "summarized_message_count" (`Int 999) canonical
  in
  let inexact_after = replace "after_message_count" (`Int 7) canonical in
  let excessive_pair_repair =
    canonical
    |> replace "after_message_count" (`Int 0)
    |> replace "pair_repair_dropped_message_count" (`Int 7)
  in
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
    ; "blank runtime", Some "   ", Empty_selected_runtime_id, canonical
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
    ; ( "tool result count increase"
      , evidence.selected_runtime_id
      , Invalid_transition (Tool_results, 3, 4)
      , replace "after_tool_result_count" (`Int 4) canonical )
    ; ( "impossible message accounting"
      , evidence.selected_runtime_id
      , Invalid_message_accounting
          { before_message_count = 12
          ; after_message_count = 6
          ; summarized_message_count = 999
          ; dropped_message_count = 1
          ; pair_repair_dropped_message_count = 0
          }
      , impossible_accounting )
    ; ( "inexact after count"
      , evidence.selected_runtime_id
      , Invalid_message_accounting
          { before_message_count = 12
          ; after_message_count = 7
          ; summarized_message_count = 6
          ; dropped_message_count = 1
          ; pair_repair_dropped_message_count = 0
          }
      , inexact_after )
    ; ( "excessive pair repair count"
      , evidence.selected_runtime_id
      , Invalid_message_accounting
          { before_message_count = 12
          ; after_message_count = 0
          ; summarized_message_count = 6
          ; dropped_message_count = 1
          ; pair_repair_dropped_message_count = 7
          }
      , excessive_pair_repair )
    ]
;;

let test_exact_pair_repair_accounting () =
  match
    Keeper_compaction_evidence.create
      ~selected_runtime_id:evidence.selected_runtime_id
      ~before_checkpoint_bytes:4096
      ~after_checkpoint_bytes:1024
      ~before_message_count:12
      ~after_message_count:4
      ~summarized_message_count:6
      ~dropped_message_count:1
      ~pair_repair_dropped_message_count:2
      ~before_tool_use_count:3
      ~after_tool_use_count:1
      ~before_tool_result_count:3
      ~after_tool_result_count:1
  with
  | Ok exact ->
    Alcotest.(check int)
      "pair-repair message drops preserved"
      2
      exact.pair_repair_dropped_message_count
  | Error error ->
    Alcotest.failf
      "exact pair-repair accounting rejected: %s"
      (Keeper_compaction_evidence.decode_error_to_string error)
;;

let test_legacy_pair_repair_migration () =
  let open Keeper_compaction_evidence in
  let restore json =
    of_json ~selected_runtime_id:evidence.selected_runtime_id json
  in
  (match restore (remove "pair_repair_dropped_message_count" canonical) with
   | Ok restored ->
     Alcotest.(check int)
       "zero pair-repair count derived"
       0
       restored.pair_repair_dropped_message_count
   | Error error ->
     Alcotest.failf
       "legacy zero pair-repair evidence rejected: %s"
       (decode_error_to_string error));
  let with_pair_repair =
    canonical
    |> replace "after_message_count" (`Int 4)
    |> remove "pair_repair_dropped_message_count"
  in
  (match restore with_pair_repair with
   | Ok restored ->
     Alcotest.(check int)
       "non-zero pair-repair count derived"
       2
       restored.pair_repair_dropped_message_count
   | Error error ->
     Alcotest.failf
       "legacy non-zero pair-repair evidence rejected: %s"
       (decode_error_to_string error));
  let impossible =
    canonical
    |> replace "after_message_count" (`Int 7)
    |> remove "pair_repair_dropped_message_count"
  in
  match restore impossible with
  | Error
      (Legacy_message_accounting_not_derivable
        { before_message_count = 12
        ; after_message_count = 7
        ; summarized_message_count = 6
        ; dropped_message_count = 1
        }) ->
    ()
  | Error error ->
    Alcotest.failf
      "unexpected legacy migration rejection: %s"
      (decode_error_to_string error)
  | Ok _ -> Alcotest.fail "impossible legacy evidence decoded"
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
        ; Alcotest.test_case
            "exact pair-repair accounting"
            `Quick
            test_exact_pair_repair_accounting
        ; Alcotest.test_case
            "legacy pair-repair migration"
            `Quick
            test_legacy_pair_repair_migration
        ] )
    ]
