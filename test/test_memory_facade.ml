module Memory = Masc.Memory
module Policy = Masc.Keeper_memory_policy

let test_memory_t_wraps_keeper_owned_types () =
  let state_snapshot : Memory.state_snapshot =
    {
      Policy.empty_keeper_state_snapshot with
      goal = Some "Keep memory in MASC";
      decisions = [ "OAS memory API removed" ];
    }
  in
  let line : Memory.line =
    {
      kind = "decision";
      text = "MASC owns memory";
      priority = 10;
      ts_unix = 42.0;
    }
  in
  let bank_summary : Memory.summary =
    {
      total_notes = 1;
      last_ts_unix = 42.0;
      top_kind = Some "decision";
      kind_counts = [ "decision", 1 ];
      recent_notes = [ line ];
    }
  in
  let memory = Memory.make ~state_snapshot ~bank_summary () in
  Alcotest.(check (option string))
    "goal"
    (Some "Keep memory in MASC")
    (Memory.state_snapshot memory).goal;
  Alcotest.(check int)
    "total_notes"
    1
    (Memory.bank_summary memory).total_notes;
  match Memory.to_json memory with
  | `Assoc fields ->
    Alcotest.(check bool)
      "state_snapshot json present"
      true
      (List.mem_assoc "state_snapshot" fields);
    Alcotest.(check bool)
      "bank_summary json present"
      true
      (List.mem_assoc "bank_summary" fields)
  | _ -> Alcotest.fail "Memory.to_json must return an object"

let test_oas_compaction_sources_are_not_memory_sources () =
  Alcotest.(check (option string))
    "oas_proactive removed"
    None
    (Option.map
       Memory.compaction_source_to_string
       (Memory.compaction_source_of_string_opt "oas_proactive"));
  Alcotest.(check (option string))
    "oas_emergency removed"
    None
    (Option.map
       Memory.compaction_source_to_string
       (Memory.compaction_source_of_string_opt "oas_emergency"));
  Alcotest.(check string)
    "masc policy source"
    "masc_policy"
    (Memory.compaction_source_to_string MASC_policy)

let () =
  Alcotest.run
    "memory_facade"
    [
      ( "owned_types",
        [
          Alcotest.test_case
            "Memory.t wraps keeper-owned memory state"
            `Quick
            test_memory_t_wraps_keeper_owned_types;
          Alcotest.test_case
            "OAS compaction source strings are not memory sources"
            `Quick
            test_oas_compaction_sources_are_not_memory_sources;
        ] );
    ]
