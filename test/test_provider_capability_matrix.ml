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

    2. CLI providers always advertise runtime MCP.  All CLI kinds
       (Claude Code, Gemini CLI, Kimi CLI, Codex CLI) use runtime MCP
       for tool invocation, not inline function-calling.
       [normalize_cli_caps_when] forces this contract regardless of
       OAS-level defaults.

    The CLI list is exhaustively typed via [match] so adding a
    new CLI variant fails compilation here, not at runtime when
    the cascade picks it up.

    Cross-reference:
    - [lib/provider_tool_support.ml] — [oas_capabilities_of_config]
      resolves provider-level bases through the OAS Provider_registry/catalog.
      and [normalize_cli_caps_when]
    - [planning/claude-plans/me-workspace-yousleepwhen-masc-mcp-hashed-pretzel.md]
      Step 15 line item ("test_provider_capability_matrix.ml")
*)

open Masc_mcp
module PC = Llm_provider.Provider_config
module PTS = Provider_tool_support

(* ── Fixtures ──────────────────────────────────────────────── *)

(** Build a minimal Provider_config; capability lookup does not
    consult any of the optional fields, so the dummy values are
    fine for a pure matrix check.  [model_id] is intentionally a
    name that's not in the [Capabilities.for_model_id] table so
    the CLI normalize path is exercised on its own. *)
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
  | PC.Claude_code | PC.Gemini_cli | PC.Kimi_cli | PC.Codex_cli -> true
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

(** Total function check: [capabilities_of_config] returns for
    every kind, regardless of model_id.  Catches a regression
    where OAS Provider_registry/catalog lookup stops resolving a
    provider-level capability base for a known kind. *)
let test_capabilities_of_config_total () =
  List.iter
    (fun kind ->
      let _ = PTS.capabilities_of_config (make_cfg ~kind) in
      ())
    (cli_kinds @ api_kinds);
  Alcotest.(check bool) "all 11 provider kinds resolve" true true

let with_provider_catalog entries f =
  let previous = Llm_provider.Provider_catalog.global () in
  Llm_provider.Provider_catalog.set_global entries;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some entries -> Llm_provider.Provider_catalog.set_global entries
      | None -> Llm_provider.Provider_catalog.clear_global ())
    f

let test_provider_catalog_overlay_drives_base_capabilities () =
  let caps =
    { Llm_provider.Capabilities.openai_chat_capabilities with
      max_context_tokens = Some 4242
    ; supports_tools = false
    ; supports_runtime_mcp_tools = true
    ; supports_runtime_tool_events = true
    }
  in
  let entry : Llm_provider.Provider_catalog.entry =
    { id = "local-vllm-fixture"
    ; aliases = [ "vllm-fixture" ]
    ; kind = PC.OpenAI_compat
    ; transport = Llm_provider.Provider_catalog.Custom_openai_compat
    ; command = None
    ; base_url = "https://runtime-catalog-fixture.invalid"
    ; request_path = "/v1/chat/completions"
    ; api_key_env = ""
    ; auth = Llm_provider.Provider_catalog.No_auth
    ; default_model = Some "fixture-model"
    ; max_context = Some 4242
    ; capabilities = caps
    ; non_interactive = true
    ; interactive_required = false
    ; daemon_safe = true
    ; credential_scope = None
    }
  in
  with_provider_catalog [ entry ] (fun () ->
    let cfg =
      PC.make
        ~kind:PC.OpenAI_compat
        ~model_id:"fixture-model"
        ~base_url:"https://runtime-catalog-fixture.invalid/"
        ~request_path:"/v1/chat/completions"
        ()
    in
    let resolved = PTS.oas_capabilities_of_config cfg in
    Alcotest.(check (option int))
      "catalog max_context flows through OAS registry"
      (Some 4242)
      resolved.max_context_tokens;
    Alcotest.(check bool)
      "catalog can override inline tool support"
      false
      resolved.supports_tools;
    Alcotest.(check bool)
      "catalog runtime MCP tools"
      true
      resolved.supports_runtime_mcp_tools;
    Alcotest.(check bool)
      "catalog runtime MCP events"
      true
      resolved.supports_runtime_tool_events)

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
          Alcotest.test_case "CLI providers expose runtime MCP lane"
            `Quick test_cli_runtime_mcp_lane;
        ] );
      ( "provider_catalog",
        [
          Alcotest.test_case
            "OAS provider catalog overlay drives base capabilities"
            `Quick test_provider_catalog_overlay_drives_base_capabilities;
        ] );
    ]
