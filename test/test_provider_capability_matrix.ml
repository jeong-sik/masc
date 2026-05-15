(** test_provider_capability_matrix — Step 15 partial.

    Pins the provider × capability matrix surfaced by
    [Provider_tool_support.capabilities_of_config].

    The matrix has two stable invariants we want to surface as
    a build break, not a fleet incident:

    1. CLI providers (Claude_code / Gemini_cli / Kimi_cli /
       Codex_cli) must NOT advertise inline tools.
       [keeper_agent_run] picks the inline-tool dispatch path
       solely from this flag; if a CLI ever flipped to [true]
       the keeper would emit OpenAI-style [tools] arrays into
       a subprocess that doesn't read them, and the turn would
       silently degrade.

    2. CLI providers advertise the runtime MCP lane according to the
       cascade.toml/OAS tool-delivery contract. Claude Code and Kimi CLI
       can carry request-scoped MCP HTTP headers, Codex CLI can use the
       per-keeper bridge declared in cascade.toml, and Gemini CLI remains
       disabled for runtime MCP until its upstream request-scoped MCP
       path is implemented.
       [normalize_cli_caps_when] preserves this contract after OAS
       capability lookup.

    The CLI list is exhaustively typed via [match] so adding a
    new CLI variant fails compilation here, not at runtime when
    the cascade picks it up.

    OAS owns provider/model capability truth through
    [Agent_sdk.Provider_runtime_binding] plus cascade.toml provider
    capabilities; this test pins MASC's local projection into
    inline/runtime tool-delivery flags.

    Cross-reference:
    - [lib/provider_tool_support.ml] — [oas_capabilities_of_config]
      and [normalize_cli_caps_when]
    - [planning/claude-plans/me-workspace-yousleepwhen-masc-mcp-hashed-pretzel.md]
      Step 15 line item ("test_provider_capability_matrix.ml")
*)

open Masc_mcp
module PC = Llm_provider.Provider_config
module PTS = Provider_tool_support

(* ── Fixtures ──────────────────────────────────────────────── *)

(** Build a minimal Provider_config.  [model_id] is intentionally absent
    from OAS's model capability table so the matrix checks provider/catalog
    capability projection rather than a model-specific override. *)
let make_cfg ~kind =
  PC.make
    ~kind
    ~model_id:"test-fixture-unknown-model"
    ~base_url:"http://localhost:0"
    ~request_path:"/"
    ()

(* Exhaustive enumerations.  The [match] in [kind_label] below
   gives us compile-time exhaustiveness; if [Provider_kind.t]
   gains a variant the test won't compile until both the label
   match and the [cli_kinds] / [api_kinds] lists are updated. *)

let cli_kinds : PC.provider_kind list =
  [ PC.Claude_code; PC.Gemini_cli; PC.Kimi_cli; PC.Codex_cli ]

let api_kinds : PC.provider_kind list =
  [
    PC.Anthropic;
    PC.Kimi;
    PC.OpenAI_compat;
    PC.Ollama;
    PC.Gemini;
    PC.Glm;
    PC.DashScope;
  ]

let kind_label : PC.provider_kind -> string = function
  | Anthropic -> "Anthropic"
  | Kimi -> "Kimi"
  | OpenAI_compat -> "OpenAI_compat"
  | Ollama -> "Ollama"
  | Gemini -> "Gemini"
  | Glm -> "Glm"
  | DashScope -> "DashScope"
  | Claude_code -> "Claude_code"
  | Gemini_cli -> "Gemini_cli"
  | Kimi_cli -> "Kimi_cli"
  | Codex_cli -> "Codex_cli"

(* ── Tests ─────────────────────────────────────────────────── *)

let test_total_kind_count () =
  Alcotest.(check int)
    "11 provider kinds (4 CLI + 7 API)" 11
    (List.length cli_kinds + List.length api_kinds)

let test_cli_no_inline_tools () =
  List.iter
    (fun kind ->
      let caps = PTS.capabilities_of_config (make_cfg ~kind) in
      Alcotest.(check bool)
        ("CLI " ^ kind_label kind ^ " must NOT advertise inline tools")
        false caps.supports_inline_tools;
      Alcotest.(check bool)
        ("CLI " ^ kind_label kind
       ^ " must NOT advertise inline tool_choice")
        false caps.supports_inline_tool_choice)
    cli_kinds

let expected_cli_runtime_mcp = function
  | PC.Claude_code | PC.Kimi_cli | PC.Codex_cli -> true
  | PC.Gemini_cli -> false
  | PC.Anthropic | PC.Kimi | PC.OpenAI_compat | PC.Ollama | PC.Gemini | PC.Glm
  | PC.DashScope ->
      false

let test_cli_runtime_mcp_lane () =
  List.iter
    (fun kind ->
      let caps = PTS.capabilities_of_config (make_cfg ~kind) in
      let expected = expected_cli_runtime_mcp kind in
      Alcotest.(check bool)
        ("CLI " ^ kind_label kind ^ " runtime MCP tools")
        expected caps.supports_runtime_mcp_tools;
      Alcotest.(check bool)
        ("CLI " ^ kind_label kind ^ " runtime tool events")
        expected caps.supports_runtime_tool_events)
    cli_kinds

(** Total function check: [capabilities_of_config] returns for every kind,
    regardless of model_id.  Provider-kind coverage belongs to OAS; this keeps
    MASC's projection total over the currently exposed provider set. *)
let test_capabilities_of_config_total () =
  List.iter
    (fun kind ->
      let _ = PTS.capabilities_of_config (make_cfg ~kind) in
      ())
    (cli_kinds @ api_kinds);
  Alcotest.(check bool) "all 11 provider kinds resolve" true true

let with_provider_catalog json f =
  match Llm_provider.Provider_catalog.of_json (Yojson.Safe.from_string json) with
  | Error msg -> Alcotest.fail msg
  | Ok catalog ->
      Llm_provider.Provider_catalog.set_global catalog;
      Fun.protect ~finally:Llm_provider.Provider_catalog.clear_global f

let catalog_disables_inline_tools_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "masc-catalog-local",
      "kind": "openai_compat",
      "transport": "http",
      "base_url": "http://127.0.0.1:8123",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "capabilities": {"supports_tools": false, "supports_tool_choice": false},
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    }
  ]
}
|}

let test_catalog_capabilities_drive_masc_projection () =
  with_provider_catalog catalog_disables_inline_tools_json (fun () ->
      let cfg =
        PC.make ~kind:PC.OpenAI_compat ~model_id:"unlisted-catalog-model"
          ~base_url:"http://127.0.0.1:8123" ~request_path:"/v1/chat/completions" ()
      in
      let caps = PTS.capabilities_of_config cfg in
      Alcotest.(check bool)
        "catalog disables inline tools"
        false caps.supports_inline_tools;
      Alcotest.(check bool)
        "catalog disables inline tool choice"
        false caps.supports_inline_tool_choice)

let () =
  Alcotest.run "provider_capability_matrix"
    [
      ( "enumeration",
        [
          Alcotest.test_case "11 kinds total (4 CLI + 7 API)"
            `Quick test_total_kind_count;
          Alcotest.test_case
            "capabilities_of_config is total over Provider_kind.t"
            `Quick test_capabilities_of_config_total;
        ] );
      ( "cli_invariants",
        [
          Alcotest.test_case "CLI providers reject inline tools"
            `Quick test_cli_no_inline_tools;
          Alcotest.test_case "CLI providers follow runtime MCP policy lane"
            `Quick test_cli_runtime_mcp_lane;
        ] );
      ( "catalog",
        [
          Alcotest.test_case
            "catalog capabilities drive MASC projection"
            `Quick test_catalog_capabilities_drive_masc_projection;
        ] );
    ]
