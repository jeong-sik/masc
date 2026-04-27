(** Boot-time audit for the provider × MCP-config-construct matrix.

    Leak 12 (2026-04-27): masc-mcp ships three sibling code paths
    that each construct (or fail to construct) a Bearer-token MCP
    config JSON for a CLI subprocess, so that an LLM running inside
    that subprocess can reach the masc-mcp HTTP server.  The defaults
    are inconsistent and the surface is not enumerable from any
    single SSOT —

    | provider     | construct path                                     | env flag                          | default |
    |--------------|----------------------------------------------------|-----------------------------------|---------|
    | claude_code  | [Keeper_cli_mcp_config.try_construct_for_keeper]   | MASC_AUTO_CONSTRUCT_CLAUDE_MCP    | true    |
    | kimi_cli     | (same module)                                      | (same)                            | true    |
    | codex_cli    | [Server_runtime_bootstrap.sync_codex_mcp_config]   | MASC_SYNC_CODEX_MCP_CONFIG        | false   |
    | gemini_cli   | none — only [OAS_GEMINI_NO_MCP] disable flag       | (only disable, no enable)         | n/a     |
    | glm          | n/a — HTTP API, OAS-side dispatch                  | n/a                               | n/a     |
    | ollama       | n/a — HTTP API, OAS-side dispatch                  | n/a                               | n/a     |

    A docker keeper whose cascade routes to a CLI provider with no
    or disabled construct path will still produce LLM responses but
    every [keeper_*] / [masc_*] tool call will fail with
    "tool not in session's tool registry."  Operators have no
    runtime signal that this is happening — there is no audit that
    reports "cascade refers to provider P, P has no construct
    path."

    This module is the SSOT for the per-provider "is auto-construct
    active" answer.  Boot hooks consume it.  PR-Mp1 (the unified
    construct API) will read from it as well so the inconsistency
    only lives in one place. *)

type construct_path =
  | Auto_construct_active of {
      env_flag : string;
      default_when_unset : bool;
      module_name : string;
    }
  | No_auto_construct_path of { reason : string }
  | Not_applicable_http_api

type result = {
  provider : string;
  construct : construct_path;
}

(** SSOT table.  Sourced from direct code inspection on 2026-04-27:

    - [keeper_cli_mcp_config.ml:16,22] — claude_code + kimi_cli
    - [server_runtime_bootstrap.ml:625,798,801] — codex_cli
    - [keeper_types_profile.ml:1298] — gemini_cli (disable flag only)
    - [llm_provider/transport_*.ml] — glm, ollama (no MCP client) *)
let lookup provider =
  let construct =
    match provider with
    | "claude_code" | "claude" ->
        Auto_construct_active
          {
            env_flag = "MASC_AUTO_CONSTRUCT_CLAUDE_MCP";
            default_when_unset = true;
            module_name = "Keeper_cli_mcp_config";
          }
    | "kimi_cli" | "kimi" ->
        (* kimi_cli reuses claude_code's construct path; the env
           flag and default_when_unset are therefore identical. *)
        Auto_construct_active
          {
            env_flag = "MASC_AUTO_CONSTRUCT_CLAUDE_MCP";
            default_when_unset = true;
            module_name = "Keeper_cli_mcp_config";
          }
    | "codex_cli" | "codex" ->
        Auto_construct_active
          {
            env_flag = "MASC_SYNC_CODEX_MCP_CONFIG";
            default_when_unset = false;
            module_name = "Server_runtime_bootstrap.sync_codex_mcp_config";
          }
    | "gemini_cli" | "gemini" ->
        No_auto_construct_path
          {
            reason =
              "no enable path; only OAS_GEMINI_NO_MCP disable flag exists \
               (keeper_types_profile.ml:1298)";
          }
    | "glm" | "glm-coding" | "ollama" ->
        Not_applicable_http_api
    | other ->
        No_auto_construct_path
          {
            reason =
              Printf.sprintf
                "provider %S not registered in MCP config matrix; either \
                 unknown or new — add it to keeper_mcp_provider_audit.lookup"
                other;
          }
  in
  { provider; construct }

(** Active-default check: is the auto-construct path on by the time
    the server boots without operator env intervention? *)
let auto_construct_active_by_default (r : result) =
  match r.construct with
  | Auto_construct_active { default_when_unset; _ } -> default_when_unset
  | No_auto_construct_path _ -> false
  | Not_applicable_http_api -> true (* HTTP API providers don't need it *)

let format_log_line (r : result) =
  match r.construct with
  | Auto_construct_active { env_flag; default_when_unset; module_name } ->
      Printf.sprintf
        "[mcp_audit:active] provider=%s default=%b env=%s module=%s"
        r.provider default_when_unset env_flag module_name
  | No_auto_construct_path { reason } ->
      Printf.sprintf
        "[mcp_audit:no_construct_path] provider=%s reason=%s" r.provider
        reason
  | Not_applicable_http_api ->
      Printf.sprintf "[mcp_audit:http_api] provider=%s" r.provider

(** Audit a list of providers (typically extracted from a cascade
    config).  Pure mapping over [lookup]. *)
let audit_providers providers =
  List.map lookup providers

(** Severity buckets: callers route [active] at debug, [http_api] at
    info, [no_construct_path] at warn. *)
let partition (results : result list) =
  List.fold_left
    (fun (active, no_path, http_api) r ->
      match r.construct with
      | Auto_construct_active _ -> (r :: active, no_path, http_api)
      | No_auto_construct_path _ -> (active, r :: no_path, http_api)
      | Not_applicable_http_api -> (active, no_path, r :: http_api))
    ([], [], []) results
