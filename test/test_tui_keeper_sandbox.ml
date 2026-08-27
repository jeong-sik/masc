let contains haystack needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern haystack 0);
    true
  with Not_found -> false

let observed =
  Yojson.Safe.from_string
    {|{
      "name": "alpha",
      "sandbox_last_error": null,
      "sandbox_live": {
        "keeper": "alpha",
        "sandbox_profile": "docker",
        "configured_network_mode": "inherit",
        "effective_mode": "oneshot_or_managed_inherit",
        "managed_container_kind": "managed",
        "containers": [],
        "preflight": null,
        "container_error": null,
        "why_no_container": "no visible managed sandbox container; network_mode=inherit uses one-shot Docker containers on sandboxed tool calls, and those containers still mount the keeper playground",
        "identity": {
          "agent_name": "keeper-alpha",
          "expected_agent_name": "keeper-alpha",
          "agent_name_matches": true,
          "warnings": []
        }
      }
    }|}

let render json =
  match
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_decode.sanitize_terminal_text
      json
  with
  | Error detail -> Alcotest.fail detail
  | Ok reading ->
    Masc_tui_keeper_sandbox.view_lines ~width:64 reading
    |> String.concat "\n"

let test_declared_effective_observed_flow () =
  let rendered = render observed in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "sandbox flow"
    ; "Declared"
    ; "docker / network inherit"
    ; "Effective"
    ; "oneshot_or_managed_inherit"
    ; "Observed"
    ; "0 observed"
    ; "Why no"
    ; "one-shot"
    ; "Docker"
    ; "containers"
    ; "Identity"
    ; "matches canonical name"
    ]

let test_live_container_and_errors_are_visible () =
  let json =
    Yojson.Safe.from_string
      {|{
        "sandbox_last_error": "previous launch failed",
        "sandbox_live": {
          "sandbox_profile": "docker",
          "configured_network_mode": "none",
          "effective_mode": "managed_running",
          "managed_container_kind": "managed",
          "containers": [{
            "id": "abc123",
            "name": "masc-alpha",
            "image": "masc/sandbox:latest",
            "status": "Up 2 minutes",
            "running": true,
            "created_at": null,
            "keeper_name": "alpha",
            "container_kind": "managed",
            "network_label": "none",
            "owner_pid": 4242,
            "started_at": 1.0,
            "ttl_sec": 60.0
          }],
          "container_error": "docker list partial",
          "why_no_container": null,
          "identity": {
            "agent_name": "wrong",
            "expected_agent_name": "keeper-alpha",
            "agent_name_matches": false,
            "warnings": ["repair identity"]
          }
        }
      }|}
  in
  let rendered = render json in
  List.iter
    (fun needle ->
      Alcotest.(check bool) needle true (contains rendered needle))
    [ "1 observed Â· 1 running"
    ; "masc-alpha"
    ; "abc123"
    ; "pid 4242"
    ; "docker list partial"
    ; "previous launch failed"
    ; "wrong expected keeper-alpha"
    ; "repair identity"
    ]

let test_hostile_text_is_sanitized_before_state () =
  let json =
    Yojson.Safe.from_string
      {|{
        "sandbox_live": {
          "effective_mode": "before\u001b]8;;https://bad.invalid\u0007after",
          "containers": []
        }
      }|}
  in
  let rendered = render json in
  Alcotest.(check bool) "raw escape is absent" false (contains rendered "\027]8");
  Alcotest.(check bool) "escaped control remains inspectable" true
    (contains rendered "\\x1B")

let test_missing_live_observation_fails_closed () =
  match
    Masc_tui_keeper_sandbox.decode ~sanitize:Fun.id (`Assoc [])
  with
  | Ok _ -> Alcotest.fail "missing sandbox_live was accepted"
  | Error detail ->
    Alcotest.(check bool) "actionable error" true
      (contains detail "no sandbox_live observation")

let () =
  Alcotest.run "tui keeper sandbox"
    [ ( "projection"
      , [ Alcotest.test_case "declared effective observed flow" `Quick
            test_declared_effective_observed_flow
        ; Alcotest.test_case "containers and errors" `Quick
            test_live_container_and_errors_are_visible
        ; Alcotest.test_case "terminal controls sanitized" `Quick
            test_hostile_text_is_sanitized_before_state
        ; Alcotest.test_case "missing observation fails closed" `Quick
            test_missing_live_observation_fails_closed
        ] )
    ]
