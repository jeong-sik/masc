let test_resolve_bind_state_skips_read_only_lookup () =
  let called = ref false in
  let bound =
    Masc.Mcp_server_eio_execute.resolve_bind_state
      ~workspace_initialized:true
      ~bind_required:false
      ~agent_name:"agent_code"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup skipped" false !called;
  Alcotest.(check bool) "read-only defaults false" false bound

let test_resolve_bind_state_checks_bind_gated_tools () =
  let called = ref false in
  let bound =
    Masc.Mcp_server_eio_execute.resolve_bind_state
      ~workspace_initialized:true
      ~bind_required:true
      ~agent_name:"agent_code"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup performed" true !called;
  Alcotest.(check bool) "bind result preserved" true bound

let test_resolve_bind_state_skips_unknown_agent () =
  let called = ref false in
  let bound =
    Masc.Mcp_server_eio_execute.resolve_bind_state
      ~workspace_initialized:true
      ~bind_required:true
      ~agent_name:"unknown"
      ~check_join:(fun _candidate ->
        called := true;
        true)
  in
  Alcotest.(check bool) "unknown agent skipped" false !called;
  Alcotest.(check bool) "unknown agent treated unbound" false bound

let test_resolve_bind_state_alias_does_not_probe_canonical () =
  let candidates = ref [] in
  let bound =
    Masc.Mcp_server_eio_execute.resolve_bind_state
      ~workspace_initialized:true
      ~bind_required:true
      ~agent_name:"agent_code-rotated"
      ~check_join:(fun candidate ->
        candidates := candidate :: !candidates;
        candidate = "keeper-agent_code-agent")
  in
  Alcotest.(check bool) "canonical alias not recovered" false bound;
  let recorded = List.rev !candidates in
  Alcotest.(check (list string))
    "only raw agent checked"
    [ "agent_code-rotated" ]
    recorded

let test_resolve_bind_state_unknown_alias_stays_false () =
  let bound =
    Masc.Mcp_server_eio_execute.resolve_bind_state
      ~workspace_initialized:true
      ~bind_required:true
      ~agent_name:"a-b"
      ~check_join:(fun _candidate -> false)
  in
  Alcotest.(check bool) "non-keeper input stays unbound" false bound

let () =
  Alcotest.run
    "Mcp_server_eio_bind_state"
    [ ( "bind_state"
      , [ ( "resolve_bind_state skips read-only lookup"
          , `Quick
          , test_resolve_bind_state_skips_read_only_lookup )
        ; ( "resolve_bind_state checks bind-gated tools"
          , `Quick
          , test_resolve_bind_state_checks_bind_gated_tools )
        ; ( "resolve_bind_state skips unknown agent"
          , `Quick
          , test_resolve_bind_state_skips_unknown_agent )
        ; ( "resolve_bind_state alias does not probe canonical"
          , `Quick
          , test_resolve_bind_state_alias_does_not_probe_canonical )
        ; ( "resolve_bind_state unknown alias stays false"
          , `Quick
          , test_resolve_bind_state_unknown_alias_stays_false )
        ] )
    ]
