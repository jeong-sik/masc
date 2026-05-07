(** RFC-0041 PR-A — Drift guards for [Endpoint.direct_endpoints].

    These tests pin the wire-level classification for the 14 endpoints. They
    verify the four §2.1 surprises (Kimi-Anthropic-hybrid, Ollama-ndjson,
    Gemini-CLI-no-per-call-MCP, GLM-no-/v1) and the structural invariants
    (1:1 with Provider_adapter, label_prefix uniqueness, CLI auth).

    PR-A scope: Endpoint module is inert (no caller). These tests are the
    only consumer. They guarantee the registry stays aligned with
    [Provider_adapter.direct_adapters] until PR-D removes the latter. *)

module E = Masc_mcp.Endpoint
module PA = Masc_mcp.Provider_adapter

(* ---- Structural: 1:1 alignment with Provider_adapter ---------------- *)

let test_count_aligns_with_provider_adapter () =
  Alcotest.(check int)
    "Endpoint and Provider_adapter registries have identical entry count"
    (List.length PA.direct_adapters)
    (List.length E.direct_endpoints)

let test_label_prefixes_unique () =
  let prefixes = List.map (fun (e : E.t) -> e.label_prefix) E.direct_endpoints in
  let unique = List.sort_uniq String.compare prefixes in
  Alcotest.(check int)
    "all label_prefixes are distinct"
    (List.length prefixes)
    (List.length unique)

(* ---- Surprise 1: Kimi API uses Anthropic body shape with Bearer auth -- *)

let test_kimi_api_anthropic_body_bearer_auth () =
  match E.find_by_label_prefix "kimi" with
  | None -> Alcotest.fail "kimi (kimi-api) endpoint missing from registry"
  | Some e ->
      (match e.body_schema with
       | E.Anthropic_content_blocks -> ()
       | _ ->
           Alcotest.fail
             "kimi-api must use Anthropic_content_blocks body schema");
      (match e.auth with
       | E.Bearer { env_var } ->
           Alcotest.(check string)
             "kimi-api uses KIMI_API_KEY_SB env var"
             "KIMI_API_KEY_SB" env_var
       | _ ->
           Alcotest.fail
             "kimi-api must use Bearer auth (OpenAI-style on Anthropic body)")

(* ---- Surprise 2: Ollama streams newline-delimited JSON, not SSE ----- *)

let test_ollama_uses_ndjson_stream () =
  match E.find_by_label_prefix "ollama" with
  | None -> Alcotest.fail "ollama endpoint missing from registry"
  | Some e ->
      (match e.stream_format with
       | E.Ndjson_ollama -> ()
       | _ ->
           Alcotest.fail
             "ollama must use Ndjson_ollama (done:true terminator carries \
              eval_count)");
      (match e.body_schema with
       | E.Ollama_options -> ()
       | _ -> Alcotest.fail "ollama must use Ollama_options body schema");
      (match e.discovery with
       | E.Ps_endpoint { path } ->
           Alcotest.(check string)
             "ollama discovery uses /api/ps"
             "/api/ps" path
       | _ -> Alcotest.fail "ollama must declare Ps_endpoint discovery")

(* ---- Surprise 3: Gemini CLI cannot accept per-call MCP config ------- *)

let test_gemini_cli_no_per_call_mcp () =
  match E.find_by_label_prefix "gemini_cli" with
  | None -> Alcotest.fail "gemini_cli endpoint missing from registry"
  | Some e ->
      Alcotest.(check bool)
        "gemini_cli supports_per_call_mcp_config is false (gemini-cli #4674 \
         unimplemented)"
        false e.capabilities.supports_per_call_mcp_config

(* ---- Surprise 4: GLM uses /chat/completions (no /v1 prefix) --------- *)

let test_glm_no_v1_path () =
  match E.find_by_label_prefix "glm" with
  | None -> Alcotest.fail "glm endpoint missing from registry"
  | Some e ->
      (match e.transport with
       | E.Http { request_path; _ } ->
           Alcotest.(check string)
             "GLM request path is /chat/completions (no /v1 prefix)"
             "/chat/completions" request_path
       | E.Cli_subprocess _ -> Alcotest.fail "glm must be Http transport");
      (match e.body_schema with
       | E.OpenAI_messages_with_thinking -> ()
       | _ ->
           Alcotest.fail
             "glm must use OpenAI_messages_with_thinking (thinking field is \
              GLM-specific)")

(* ---- All CLI transports use Cli_cached_login ------------------------ *)

let test_cli_transports_use_cached_login () =
  let cli_endpoints =
    List.filter
      (fun (e : E.t) ->
        match e.transport with
        | E.Cli_subprocess _ -> true
        | E.Http _ -> false)
      E.direct_endpoints
  in
  Alcotest.(check int)
    "exactly 4 CLI subprocess endpoints (claude, codex, gemini, kimi)"
    4 (List.length cli_endpoints);
  List.iter
    (fun (e : E.t) ->
      match e.auth with
      | E.Cli_cached_login -> ()
      | _ ->
          Alcotest.failf
            "CLI endpoint %s must use Cli_cached_login (got different auth)"
            e.label_prefix)
    cli_endpoints

(* ---- All Local endpoints (Http + None_required) declare discovery --- *)

let test_local_http_endpoints_declare_discovery () =
  let local_http =
    List.filter
      (fun (e : E.t) ->
        match e.transport, e.auth with
        | E.Http _, E.None_required -> true
        | _ -> false)
      E.direct_endpoints
  in
  Alcotest.(check int)
    "exactly 2 local HTTP endpoints (llama, ollama) — both auth-free"
    2 (List.length local_http);
  List.iter
    (fun (e : E.t) ->
      match e.discovery with
      | E.No_discovery ->
          Alcotest.failf
            "local endpoint %s must declare a discovery method (Models or \
             Ps endpoint)"
            e.label_prefix
      | _ -> ())
    local_http

(* ---- find_by_label_prefix round-trip -------------------------------- *)

let test_find_by_label_prefix_round_trip () =
  List.iter
    (fun (e : E.t) ->
      match E.find_by_label_prefix e.label_prefix with
      | Some found ->
          Alcotest.(check bool)
            (Printf.sprintf
               "find_by_label_prefix(%s) returns the same endpoint"
               e.label_prefix)
            true (E.equal e found)
      | None ->
          Alcotest.failf
            "find_by_label_prefix(%s) returned None for registered endpoint"
            e.label_prefix)
    E.direct_endpoints;
  match E.find_by_label_prefix "nonexistent-vllm-future" with
  | None -> ()
  | Some _ ->
      Alcotest.fail "find_by_label_prefix must return None for unknown prefix"

(* ---- Anthropic claude API includes anthropic-version header --------- *)

let test_claude_api_anthropic_version_header () =
  match E.find_by_label_prefix "claude" with
  | None -> Alcotest.fail "claude (claude-api) endpoint missing"
  | Some e ->
      (match e.auth with
       | E.X_api_key { env_var; version_header = Some (k, v) } ->
           Alcotest.(check string)
             "claude-api uses ANTHROPIC_API_KEY"
             "ANTHROPIC_API_KEY" env_var;
           Alcotest.(check string) "version header key" "anthropic-version" k;
           Alcotest.(check string) "version header value" "2023-06-01" v
       | _ ->
           Alcotest.fail
             "claude-api must use X_api_key with anthropic-version header")

(* ---- Test runner ---------------------------------------------------- *)

let () =
  Alcotest.run "endpoint_rfc_0041" [
    ("structural", [
      Alcotest.test_case "1:1 alignment with Provider_adapter" `Quick
        test_count_aligns_with_provider_adapter;
      Alcotest.test_case "label_prefix uniqueness" `Quick
        test_label_prefixes_unique;
    ]);
    ("§2.1 wire-level surprises", [
      Alcotest.test_case "kimi-api: Anthropic body + Bearer auth" `Quick
        test_kimi_api_anthropic_body_bearer_auth;
      Alcotest.test_case "ollama: ndjson stream + Ps_endpoint discovery"
        `Quick test_ollama_uses_ndjson_stream;
      Alcotest.test_case "gemini_cli: no per-call MCP config" `Quick
        test_gemini_cli_no_per_call_mcp;
      Alcotest.test_case "glm: /chat/completions (no /v1) + thinking field"
        `Quick test_glm_no_v1_path;
    ]);
    ("auth and transport invariants", [
      Alcotest.test_case "all 4 CLI subprocess endpoints use Cli_cached_login"
        `Quick test_cli_transports_use_cached_login;
      Alcotest.test_case
        "local HTTP endpoints (llama, ollama) declare discovery"
        `Quick test_local_http_endpoints_declare_discovery;
      Alcotest.test_case "claude-api includes anthropic-version header"
        `Quick test_claude_api_anthropic_version_header;
    ]);
    ("lookup", [
      Alcotest.test_case "find_by_label_prefix round-trip + None for unknown"
        `Quick test_find_by_label_prefix_round_trip;
    ]);
  ]
