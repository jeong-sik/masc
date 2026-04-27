(** Tests for [Keeper_mcp_provider_audit] (Leak 12 / PR-Mp3). *)

module Audit = Masc_mcp.Keeper_mcp_provider_audit

(* ── SSOT entries ──────────────────────────────────────────────── *)

let test_claude_code_active_default_true () =
  let r = Audit.lookup "claude_code" in
  match r.construct with
  | Audit.Auto_construct_active { env_flag; default_when_unset; _ } ->
      Alcotest.(check string)
        "env flag" "MASC_AUTO_CONSTRUCT_CLAUDE_MCP" env_flag;
      Alcotest.(check bool) "default true" true default_when_unset
  | _ -> Alcotest.fail "claude_code must be Auto_construct_active"

let test_kimi_cli_aliases_to_claude_path () =
  let r = Audit.lookup "kimi_cli" in
  match r.construct with
  | Audit.Auto_construct_active { env_flag; module_name; _ } ->
      Alcotest.(check string)
        "shares claude env flag" "MASC_AUTO_CONSTRUCT_CLAUDE_MCP" env_flag;
      Alcotest.(check string)
        "shares claude module" "Keeper_cli_mcp_config" module_name
  | _ -> Alcotest.fail "kimi_cli must reuse claude_code construct path"

let test_codex_cli_active_default_false () =
  let r = Audit.lookup "codex_cli" in
  match r.construct with
  | Audit.Auto_construct_active { env_flag; default_when_unset; _ } ->
      Alcotest.(check string) "env flag" "MASC_SYNC_CODEX_MCP_CONFIG" env_flag;
      Alcotest.(check bool)
        "default false (operator must opt in)" false default_when_unset
  | _ -> Alcotest.fail "codex_cli must be Auto_construct_active"

let test_gemini_cli_no_construct_path () =
  let r = Audit.lookup "gemini_cli" in
  match r.construct with
  | Audit.No_auto_construct_path _ -> ()
  | _ ->
      Alcotest.fail
        "gemini_cli has no enable path; only OAS_GEMINI_NO_MCP disable flag"

let test_glm_is_http_api () =
  let r = Audit.lookup "glm" in
  match r.construct with
  | Audit.Not_applicable_http_api -> ()
  | _ -> Alcotest.fail "glm is HTTP API, no MCP client"

let test_ollama_is_http_api () =
  let r = Audit.lookup "ollama" in
  match r.construct with
  | Audit.Not_applicable_http_api -> ()
  | _ -> Alcotest.fail "ollama is HTTP API, no MCP client"

let test_unknown_provider_fails_loud () =
  let r = Audit.lookup "totally-fake-provider-xyz" in
  match r.construct with
  | Audit.No_auto_construct_path { reason } ->
      (* Reason must point at this module so a new cascade entry
         that adds an unknown provider surfaces the audit gap
         rather than silently returning a permissive default. *)
      let mentions_module =
        let needle = "keeper_mcp_provider_audit" in
        let h = String.lowercase_ascii reason in
        let n = String.length needle in
        let h_len = String.length h in
        let rec loop i =
          if i + n > h_len then false
          else if String.sub h i n = needle then true
          else loop (i + 1)
        in
        loop 0
      in
      Alcotest.(check bool)
        "reason references audit module" true mentions_module
  | _ ->
      Alcotest.fail
        "unknown provider must be No_auto_construct_path with diagnostic"

(* ── auto_construct_active_by_default semantics ───────────────── *)

let test_active_default_claude_true () =
  Alcotest.(check bool)
    "claude_code default-on" true
    (Audit.auto_construct_active_by_default (Audit.lookup "claude_code"))

let test_active_default_codex_false () =
  Alcotest.(check bool)
    "codex_cli default-off — Leak 12 root cause" false
    (Audit.auto_construct_active_by_default (Audit.lookup "codex_cli"))

let test_active_default_gemini_false () =
  Alcotest.(check bool)
    "gemini_cli has no construct path" false
    (Audit.auto_construct_active_by_default (Audit.lookup "gemini_cli"))

let test_active_default_glm_true () =
  (* HTTP API providers don't need a construct path; treating them
     as "active by default" lets boot hooks emit a single warn list
     of providers that actually need attention. *)
  Alcotest.(check bool)
    "glm is HTTP API, considered satisfied" true
    (Audit.auto_construct_active_by_default (Audit.lookup "glm"))

(* ── audit_providers + partition ─────────────────────────────── *)

let test_audit_providers_partitions_correctly () =
  let providers =
    [ "claude_code"; "codex_cli"; "gemini_cli"; "glm"; "ollama" ]
  in
  let results = Audit.audit_providers providers in
  Alcotest.(check int) "5 providers in" 5 (List.length results);
  let active, no_path, http_api = Audit.partition results in
  Alcotest.(check int) "2 active (claude+codex)" 2 (List.length active);
  Alcotest.(check int) "1 no construct path (gemini)" 1 (List.length no_path);
  Alcotest.(check int) "2 http api (glm+ollama)" 2 (List.length http_api)

(* ── log line tags ───────────────────────────────────────────── *)

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let test_format_log_tags () =
  Alcotest.(check bool)
    "active tag" true
    (starts_with "[mcp_audit:active]"
       (Audit.format_log_line (Audit.lookup "claude_code")));
  Alcotest.(check bool)
    "no_construct_path tag" true
    (starts_with "[mcp_audit:no_construct_path]"
       (Audit.format_log_line (Audit.lookup "gemini_cli")));
  Alcotest.(check bool)
    "http_api tag" true
    (starts_with "[mcp_audit:http_api]"
       (Audit.format_log_line (Audit.lookup "ollama")))

let () =
  Alcotest.run "Keeper MCP Provider Audit"
    [
      ( "SSOT entries",
        [
          Alcotest.test_case "claude_code default true" `Quick
            test_claude_code_active_default_true;
          Alcotest.test_case "kimi_cli aliases claude" `Quick
            test_kimi_cli_aliases_to_claude_path;
          Alcotest.test_case "codex_cli default false" `Quick
            test_codex_cli_active_default_false;
          Alcotest.test_case "gemini_cli no construct path" `Quick
            test_gemini_cli_no_construct_path;
          Alcotest.test_case "glm is HTTP API" `Quick test_glm_is_http_api;
          Alcotest.test_case "ollama is HTTP API" `Quick
            test_ollama_is_http_api;
          Alcotest.test_case "unknown provider fails loud" `Quick
            test_unknown_provider_fails_loud;
        ] );
      ( "auto_construct_active_by_default semantics",
        [
          Alcotest.test_case "claude default-on" `Quick
            test_active_default_claude_true;
          Alcotest.test_case "codex default-off (Leak 12 root)" `Quick
            test_active_default_codex_false;
          Alcotest.test_case "gemini no path => false" `Quick
            test_active_default_gemini_false;
          Alcotest.test_case "glm http_api => true" `Quick
            test_active_default_glm_true;
        ] );
      ( "aggregation",
        [
          Alcotest.test_case "audit_providers + partition" `Quick
            test_audit_providers_partitions_correctly;
        ] );
      ( "log format",
        [ Alcotest.test_case "tag prefixes" `Quick test_format_log_tags ] );
    ]
