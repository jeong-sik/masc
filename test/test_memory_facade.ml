module Memory = Masc.Memory

let test_memory_t_wraps_durable_bank_only () =
  let line : Memory.line =
    { kind = "decision"
    ; text = "MASC owns durable memory"
    ; priority = 10
    ; ts_unix = 42.0
    }
  in
  let bank_summary : Memory.summary =
    { total_notes = 1
    ; last_ts_unix = 42.0
    ; top_kind = Some "decision"
    ; kind_counts = [ "decision", 1 ]
    ; recent_notes = [ line ]
    }
  in
  let memory = Memory.make ~bank_summary () in
  Alcotest.(check int)
    "total notes"
    1
    (Memory.bank_summary memory).total_notes;
  match Memory.to_json memory with
  | `Assoc fields ->
    Alcotest.(check bool)
      "bank summary present"
      true
      (List.mem_assoc "bank_summary" fields);
    Alcotest.(check bool)
      "compaction present"
      true
      (List.mem_assoc "last_compaction" fields);
    Alcotest.(check (list string))
      "facade has no reply-derived continuity payload"
      [ "bank_summary"; "last_compaction" ]
      (List.map fst fields)
  | _ -> Alcotest.fail "Memory.to_json must return an object"
;;

let test_oas_compaction_sources_are_not_memory_sources () =
  Alcotest.(check (option string))
    "oas proactive removed"
    None
    (Option.map
       Memory.compaction_source_to_string
       (Memory.compaction_source_of_string_opt "oas_proactive"));
  Alcotest.(check (option string))
    "oas emergency removed"
    None
    (Option.map
       Memory.compaction_source_to_string
       (Memory.compaction_source_of_string_opt "oas_emergency"));
  Alcotest.(check string)
    "MASC policy source"
    "masc_policy"
    (Memory.compaction_source_to_string MASC_policy)
;;

let () =
  Alcotest.run
    "memory_facade"
    [ ( "owned_types"
      , [ Alcotest.test_case
            "Memory.t contains durable bank state only"
            `Quick
            test_memory_t_wraps_durable_bank_only
        ; Alcotest.test_case
            "OAS compaction source strings are rejected"
            `Quick
            test_oas_compaction_sources_are_not_memory_sources
        ] )
    ]
;;
