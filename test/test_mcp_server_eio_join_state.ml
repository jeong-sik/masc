let test_resolve_join_state_skips_read_only_lookup () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:false
      ~agent_name:"codex"
      ~base_path:"/tmp/masc-test-resolve-join"
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
      ~agent_name:"codex"
      ~base_path:"/tmp/masc-test-resolve-join"
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
      ~base_path:"/tmp/masc-test-resolve-join"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "unknown agent skipped" false !called;
  Alcotest.(check bool) "unknown agent treated unjoined" false joined

let test_resolve_join_state_alias_resolves_to_canonical () =
  let candidates = ref [] in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"codex-happy-shark"
      ~base_path:"/tmp/masc-test-resolve-join"
      ~check_join:(fun candidate ->
        candidates := candidate :: !candidates;
        candidate = "keeper-codex-agent")
  in
  Alcotest.(check bool) "join recovered via canonical" true joined;
  let recorded = List.rev !candidates in
  Alcotest.(check bool)
    "raw alias attempted first"
    true
    (List.length recorded >= 1 && List.hd recorded = "codex-happy-shark");
  Alcotest.(check bool)
    "canonical agent form considered"
    true
    (List.exists (String.equal "keeper-codex-agent") recorded)

let test_resolve_join_state_unknown_alias_stays_false () =
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"a-b"
      ~base_path:"/tmp/masc-test-resolve-join"
      ~check_join:(fun _candidate -> false)
  in
  Alcotest.(check bool) "non-keeper input stays unjoined" false joined

let test_should_read_legacy_persisted_agent_name () =
  let should_read =
    Masc_mcp.Mcp_server_eio_caller_identity
    .should_read_legacy_persisted_agent_name
  in
  Alcotest.(check bool)
    "ephemeral fallback reads legacy state"
    true
    (should_read ~has_explicit_agent_name:false ~agent_name:"agent-12345678");
  Alcotest.(check bool)
    "stable nickname skips legacy read"
    false
    (should_read ~has_explicit_agent_name:false ~agent_name:"codex-swift-fox");
  Alcotest.(check bool)
    "explicit agent name skips legacy read"
    false
    (should_read ~has_explicit_agent_name:true ~agent_name:"agent-12345678")

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
        ; ( "resolve_join_state alias resolves to canonical"
          , `Quick
          , test_resolve_join_state_alias_resolves_to_canonical )
        ; ( "resolve_join_state unknown alias stays false"
          , `Quick
          , test_resolve_join_state_unknown_alias_stays_false )
        ; ( "legacy persisted agent read only for ephemeral names"
          , `Quick
          , test_should_read_legacy_persisted_agent_name )
        ] )
    ]
