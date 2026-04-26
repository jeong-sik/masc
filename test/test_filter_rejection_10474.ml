(** #10474: pin the [classify_rejection] vocabulary that feeds
    [masc_cascade_filter_rejection_total]. Each branch represents
    a distinct operator action, so collapsing the labels would
    erase the actionable diagnosis ("swap to stdio MCP" vs "add
    a header-capable provider" vs "fix cascade authoring"). *)

open Alcotest
module P = Masc_mcp.Provider_tool_support
module L = Llm_provider

(* Build a minimal Provider_config; [Provider_config.make] applies
   per-kind defaults so the test stays aligned with capability
   resolution (which keys off [kind] + [model_id]). *)
let make_provider ~kind ~model_id = L.Provider_config.make ~kind ~model_id ~base_url:"" ()
let codex = make_provider ~kind:Codex_cli ~model_id:"gpt-5.4"
let kimi = make_provider ~kind:Kimi_cli ~model_id:"kimi-for-coding"

let policy_with_headers : L.Llm_transport.runtime_mcp_policy =
  { L.Llm_transport.empty_runtime_mcp_policy with
    servers =
      [ L.Llm_transport.Http_server
          { name = "test_http"
          ; url = "https://example/mcp"
          ; headers = [ "authorization", "Bearer x" ]
          }
      ]
  }
;;

let policy_without_headers : L.Llm_transport.runtime_mcp_policy =
  { L.Llm_transport.empty_runtime_mcp_policy with
    servers =
      [ L.Llm_transport.Stdio_server
          { name = "test_stdio"; command = "mcp"; args = []; env = [] }
      ]
  }
;;

let label = function
  | Some r -> P.rejection_reason_label r
  | None -> "<accepted>"
;;

(* Codex_cli has tool_policy=no_tool_http_headers; so it cannot satisfy
   a runtime_mcp_policy that needs headers. *)
let test_codex_blocked_by_headers () =
  let r =
    P.classify_rejection
      ~runtime_mcp_policy:policy_with_headers
      ~require_tool_choice_support:true
      ~require_tool_support:true
      codex
  in
  check
    string
    "codex_cli rejected with header-required policy"
    "runtime_mcp_http_headers_required"
    (label r)
;;

(* Kimi_cli's normalize_cli_provider_caps sets runtime_mcp_tools=true
   AND supports_tool_choice=false; so it relies entirely on runtime
   mcp. With a policy that demands HTTP headers and kimi_cli's
   no_tool_http_headers policy, the rejection cause is the same as
   codex — the tool_policy mismatch, not capability gaps. *)
let test_kimi_blocked_by_headers () =
  let r =
    P.classify_rejection
      ~runtime_mcp_policy:policy_with_headers
      ~require_tool_choice_support:true
      ~require_tool_support:true
      kimi
  in
  check
    string
    "kimi_cli rejected with header-required policy"
    "runtime_mcp_http_headers_required"
    (label r)
;;

(* Without HTTP headers in the policy, kimi_cli passes via runtime
   mcp because it has runtime_mcp_tools=true. *)
let test_kimi_passes_stdio_policy () =
  let r =
    P.classify_rejection
      ~runtime_mcp_policy:policy_without_headers
      ~require_tool_choice_support:true
      ~require_tool_support:true
      kimi
  in
  check string "kimi_cli accepted with stdio-only policy" "<accepted>" (label r)
;;

let test_filter_disabled () =
  let r =
    P.classify_rejection
      ~require_tool_choice_support:false
      ~require_tool_support:false
      codex
  in
  check string "filter disabled returns None" "<accepted>" (label r)
;;

let () =
  run
    "filter_rejection_10474"
    [ ( "classify_rejection"
      , [ test_case
            "codex_cli blocked by HTTP-headers policy"
            `Quick
            test_codex_blocked_by_headers
        ; test_case
            "kimi_cli blocked by HTTP-headers policy"
            `Quick
            test_kimi_blocked_by_headers
        ; test_case
            "kimi_cli passes stdio-only policy"
            `Quick
            test_kimi_passes_stdio_policy
        ; test_case "filter disabled bypasses classification" `Quick test_filter_disabled
        ] )
    ]
;;
