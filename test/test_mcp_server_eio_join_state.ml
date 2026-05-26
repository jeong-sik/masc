let test_resolve_join_state_skips_read_only_lookup () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:false
      ~agent_name:"agent_code"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup skipped" false !called;
  Alcotest.(check bool) "read-only defaults false" false joined

let test_resolve_join_state_checks_join_required_tools () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"agent_code"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup performed" true !called;
  Alcotest.(check bool) "join result preserved" true joined

let test_resolve_join_state_skips_unknown_agent () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"unknown"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "unknown agent skipped" false !called;
  Alcotest.(check bool) "unknown agent treated unjoined" false joined

let test_resolve_join_state_alias_does_not_probe_canonical () =
  let candidates = ref [] in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"agent_code-rotated"
      ~check_join:(fun candidate ->
        candidates := candidate :: !candidates;
        candidate = "keeper-agent_code-agent")
  in
  Alcotest.(check bool) "canonical alias not recovered" false joined;
  let recorded = List.rev !candidates in
  Alcotest.(check (list string))
    "only raw agent checked"
    [ "agent_code-rotated" ]
    recorded

let test_resolve_join_state_unknown_alias_stays_false () =
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"a-b"
      ~check_join:(fun _candidate -> false)
  in
  Alcotest.(check bool) "non-keeper input stays unjoined" false joined

let () =
  Alcotest.run
    "Mcp_server_eio_join_state"
    [ ( "join_state"
      , [ ( "resolve_join_state skips read-only lookup"
          , `Quick
          , test_resolve_join_state_skips_read_only_lookup )
        ; ( "resolve_join_state checks join-required tools"
          , `Quick
          , test_resolve_join_state_checks_join_required_tools )
        ; ( "resolve_join_state skips unknown agent"
          , `Quick
          , test_resolve_join_state_skips_unknown_agent )
        ; ( "resolve_join_state alias does not probe canonical"
          , `Quick
          , test_resolve_join_state_alias_does_not_probe_canonical )
        ; ( "resolve_join_state unknown alias stays false"
          , `Quick
          , test_resolve_join_state_unknown_alias_stays_false )
        ] )
    ]
