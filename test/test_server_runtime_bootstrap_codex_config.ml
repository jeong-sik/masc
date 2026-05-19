open Masc_mcp

let test_codex_mcp_config_sync_updates_only_masc_section () =
  let content =
    {|[mcp_servers.other]
http_headers = { Authorization = "Bearer keep-other" }

[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers_extra = "keep-extra"
http_headers = { Authorization = "Bearer stale" }
bearer_token_env_var = "OLD_TOKEN"

[mcp_servers.masc.tools.status]
http_headers = { Authorization = "Bearer nested-should-stay" }
|}
  in
  let expected =
    {|[mcp_servers.other]
http_headers = { Authorization = "Bearer keep-other" }

[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers_extra = "keep-extra"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"

[mcp_servers.masc.tools.status]
http_headers = { Authorization = "Bearer nested-should-stay" }
|}
  in
  let updated, status =
    Server_runtime_bootstrap.sync_codex_mcp_auth_header_content content
  in
  Alcotest.(check string) "masc section updated" expected updated;
  Alcotest.(check bool) "reported updated" true
    (status = Server_runtime_bootstrap.Codex_mcp_config_updated)

let test_codex_mcp_config_sync_missing_header_is_inserted () =
  let content =
    {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
|}
  in
  let expected =
    {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"
|}
  in
  let updated, status =
    Server_runtime_bootstrap.sync_codex_mcp_auth_header_content content
  in
  Alcotest.(check string) "missing config inserted" expected updated;
  Alcotest.(check bool) "reported updated" true
    (status = Server_runtime_bootstrap.Codex_mcp_config_updated)

let test_codex_mcp_config_sync_strips_standalone_authorization_in_masc_section
    () =
  let content =
    {|[mcp_servers.other]
Authorization = "Bearer keep-other"

[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
Authorization = "Bearer stale-literal"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"

[mcp_servers.masc.tools.status]
Authorization = "Bearer nested-keep"
|}
  in
  let expected =
    {|[mcp_servers.other]
Authorization = "Bearer keep-other"

[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"

[mcp_servers.masc.tools.status]
Authorization = "Bearer nested-keep"
|}
  in
  let updated, status =
    Server_runtime_bootstrap.sync_codex_mcp_auth_header_content content
  in
  Alcotest.(check string) "standalone authorization stripped from masc" expected
    updated;
  Alcotest.(check bool) "reported updated" true
    (status = Server_runtime_bootstrap.Codex_mcp_config_updated)

let test_codex_mcp_config_sync_strips_standalone_authorization_when_no_bearer_env
    () =
  let content =
    {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
Authorization = "Bearer stale-literal"
|}
  in
  let expected =
    {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"
|}
  in
  (* Authorization is stripped; http_headers and bearer_token_env_var are
     inserted because they are absent. *)
  let updated, status =
    Server_runtime_bootstrap.sync_codex_mcp_auth_header_content content
  in
  Alcotest.(check string) "authorization stripped, canonical bindings inserted"
    expected updated;
  Alcotest.(check bool) "reported updated" true
    (status = Server_runtime_bootstrap.Codex_mcp_config_updated)

let () =
  Alcotest.run "Server_runtime_bootstrap_codex_config"
    [
      ( "codex_mcp_config_sync",
        [
          Alcotest.test_case "updates only masc section" `Quick
            test_codex_mcp_config_sync_updates_only_masc_section;
          Alcotest.test_case "missing header is inserted" `Quick
            test_codex_mcp_config_sync_missing_header_is_inserted;
          Alcotest.test_case
            "strips standalone Authorization from masc section"
            `Quick
            test_codex_mcp_config_sync_strips_standalone_authorization_in_masc_section;
          Alcotest.test_case
            "strips standalone Authorization when no bearer env"
            `Quick
            test_codex_mcp_config_sync_strips_standalone_authorization_when_no_bearer_env;
        ] );
    ]
