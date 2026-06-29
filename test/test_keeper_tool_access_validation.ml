(* RFC-0273 §3.1 — set_policy tool_access validation (delta-only known-name
   check). Pure-function coverage of Server_dashboard_http_keeper_api_post
   .unknown_added_tool_names: newly-added names must be known candidates; names
   already on the keeper are grandfathered; removals are always allowed. *)

module P = Server_dashboard_http_keeper_api_post

let check_names msg expected actual = Alcotest.(check (list string)) msg expected actual
let check_labels msg expected actual = Alcotest.(check (list string)) msg expected actual

let candidates = [ "masc_status"; "WebSearch"; "WebFetch"; "masc_board_post" ]

let thinking ?(ts = 1.0) ?(redacted = false) content =
  Trajectory.Thinking
    { ts
    ; ts_iso = "2026-06-29T00:00:00Z"
    ; turn = 1
    ; content
    ; content_length = String.length content
    ; redacted
    }
;;

let tool_call ?(ts = 1.5) tool_name =
  Trajectory.Tool_call
    { ts
    ; ts_iso = "2026-06-29T00:00:01Z"
    ; turn = 1
    ; round = 1
    ; tool_name
    ; args_json = "{}"
    ; gate_decision = Trajectory.Pass
    ; result = None
    ; duration_ms = 0
    ; error = None
    ; cost_usd = 0.0
    ; execution_id = None
    }
;;

let line_label = function
  | Trajectory.Thinking entry ->
    Printf.sprintf "thinking:%s:%b" entry.content entry.redacted
  | Trajectory.Tool_call entry -> "tool:" ^ entry.tool_name
;;

let test_all_known_accepted () =
  check_names "all known -> nothing rejected" []
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "WebSearch" ])

let test_unknown_rejected () =
  check_names "newly-added unknown -> rejected" [ "masc_bogus" ]
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "masc_bogus" ])

let test_legacy_grandfathered () =
  (* A stale/renamed name already persisted on the keeper is NOT re-validated,
     so a legacy keeper stays editable. *)
  check_names "pre-existing unknown grandfathered" []
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_renamed_old" ]
       ~requested:[ "masc_renamed_old"; "masc_status" ])

let test_new_unknown_amid_legacy () =
  check_names "only the newly-added unknown is reported" [ "masc_typo" ]
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_renamed_old" ]
       ~requested:[ "masc_renamed_old"; "masc_status"; "masc_typo" ])

let test_removal_allowed () =
  check_names "removing a name -> nothing rejected" []
    (P.unknown_added_tool_names ~candidate_names:candidates
       ~existing:[ "masc_status"; "WebSearch" ] ~requested:[ "masc_status" ])

let test_multiple_unknown_reported_in_order () =
  check_names "all newly-added unknowns reported in request order"
    [ "z_bad"; "a_bad" ]
    (P.unknown_added_tool_names ~candidate_names:candidates ~existing:[]
       ~requested:[ "masc_status"; "z_bad"; "WebFetch"; "a_bad" ])

let test_dedupe_thinking_lines_preserves_order_and_tool_calls () =
  let lines =
    [ thinking "same"
    ; tool_call "keeper_board_post"
    ; thinking "same"
    ; thinking ~redacted:true "same"
    ; thinking "other"
    ]
  in
  let deduped = P.dedupe_thinking_lines lines in
  check_labels "drops exact duplicate thinking only"
    [ "thinking:same:false"
    ; "tool:keeper_board_post"
    ; "thinking:same:true"
    ; "thinking:other:false"
    ]
    (List.map line_label deduped)

let test_dedupe_thinking_lines_keeps_distinct_float_timestamps () =
  let lines =
    [ thinking ~ts:1.0000001 "same"; thinking ~ts:1.0000002 "same" ]
  in
  Alcotest.(check int)
    "sub-microsecond-distinct timestamps stay distinct"
    2
    (P.dedupe_thinking_lines lines |> List.length)

let () =
  Alcotest.run "keeper_tool_access_validation"
    [ ( "delta"
      , [ Alcotest.test_case "all known accepted" `Quick test_all_known_accepted
        ; Alcotest.test_case "unknown rejected" `Quick test_unknown_rejected
        ; Alcotest.test_case "legacy grandfathered" `Quick test_legacy_grandfathered
        ; Alcotest.test_case "new unknown amid legacy" `Quick test_new_unknown_amid_legacy
        ; Alcotest.test_case "removal allowed" `Quick test_removal_allowed
        ; Alcotest.test_case
            "multiple unknown in order"
            `Quick
            test_multiple_unknown_reported_in_order
        ] )
    ; ( "runtime_trace"
      , [ Alcotest.test_case
            "thinking dedupe preserves order and tool calls"
            `Quick
            test_dedupe_thinking_lines_preserves_order_and_tool_calls
        ; Alcotest.test_case
            "thinking dedupe keeps distinct float timestamps"
            `Quick
            test_dedupe_thinking_lines_keeps_distinct_float_timestamps
        ] )
    ]
