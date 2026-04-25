(* #10049: auto-construct Claude Code / Kimi CLI MCP config JSON for
   keepers whose cascade includes those CLI providers but whose env
   (OAS_CLAUDE_MCP_CONFIG) is unset.

   Without this fallback, Claude Code / Kimi CLI launches with no
   [mcpServers] entry and the keeper cannot reach the masc-mcp HTTP
   endpoint; tool calls surface as "keeper_shell not in session's tool
   registry". See #10049 for the full root-cause analysis and the
   codex_cli sibling path in [server_runtime_bootstrap.sync_codex_mcp_config].

   Gated behind [MASC_AUTO_CONSTRUCT_CLAUDE_MCP] (default true since
   #10059 validation; the legacy explicit-env path still wins when
   [OAS_CLAUDE_MCP_CONFIG] is set, and operators can opt out with
   [MASC_AUTO_CONSTRUCT_CLAUDE_MCP=false]). *)

let feature_flag_env = "MASC_AUTO_CONSTRUCT_CLAUDE_MCP"

(* Default true: PR #10059 validated the auto-construct path under flag-gated
   rollout; running without it leaves CLI keeper subprocesses with empty
   mcpServers, which breaks every keeper_* tool call. Operators can still
   opt out with [MASC_AUTO_CONSTRUCT_CLAUDE_MCP=false]. *)
let feature_enabled () =
  Env_config_core.get_bool ~default:true feature_flag_env

let build_json ~url ~bearer_token =
  let json =
    `Assoc
      [
        ( "mcpServers",
          `Assoc
            [
              ( "masc",
                `Assoc
                  [
                    "url", `String url;
                    "type", `String "http";
                    ( "headers",
                      `Assoc
                        [ "Authorization", `String ("Bearer " ^ bearer_token) ] );
                  ] );
            ] );
      ]
  in
  Yojson.Safe.to_string json

let try_construct_for_keeper ~base_path ~agent_name =
  if not (feature_enabled ()) then None
  else
    let token_file =
      Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")
    in
    if not (Sys.file_exists token_file) then None
    else
      try
        let raw_token = String.trim (Fs_compat.load_file token_file) in
        if String.equal raw_token "" then None
        else
          let host = Env_config_core.masc_host () in
          let port = Env_config_core.masc_http_port_int () in
          let url = Printf.sprintf "http://%s:%d/mcp" host port in
          Some (build_json ~url ~bearer_token:raw_token)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> None
