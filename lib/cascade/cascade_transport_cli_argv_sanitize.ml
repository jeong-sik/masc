(* UTF-8 argv sanitization for CLI-driven LLM transports.

   CLI-bound providers (codex, claude_code, gemini, json-stream variants)
   cannot accept invalid UTF-8 in argv/env/payload without misbehaving;
   this layer scrubs strings through [Inference_utils.sanitize_text_utf8]
   before they cross the transport boundary.

   Extracted from [Cascade_transport] (godfile decomp). All functions
   are pure mappings over [Llm_provider.Llm_transport] values. *)

let sanitize_runtime_mcp_server_for_cli =
  let sanitize = Inference_utils.sanitize_text_utf8 in
  function
  | Llm_provider.Llm_transport.Stdio_server { name; command; args; env } ->
    Llm_provider.Llm_transport.Stdio_server
      { name = sanitize name
      ; command = sanitize command
      ; args = List.map sanitize args
      ; env = List.map (fun (key, value) -> sanitize key, sanitize value) env
      }
  | Llm_provider.Llm_transport.Http_server { name; url; headers } ->
    Llm_provider.Llm_transport.Http_server
      { name = sanitize name
      ; url = sanitize url
      ; headers = List.map (fun (key, value) -> sanitize key, sanitize value) headers
      }
;;

let sanitize_runtime_mcp_policy_for_cli
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  let sanitize = Inference_utils.sanitize_text_utf8 in
  { policy with
    servers = List.map sanitize_runtime_mcp_server_for_cli policy.servers
  ; allowed_server_names = List.map sanitize policy.allowed_server_names
  ; allowed_tool_names = List.map sanitize policy.allowed_tool_names
  ; permission_mode = Option.map sanitize policy.permission_mode
  ; approval_mode = Option.map sanitize policy.approval_mode
  }
;;

let sanitize_cli_completion_request_for_argv
      (req : Llm_provider.Llm_transport.completion_request)
  =
  { req with
    config =
      { req.config with
        system_prompt =
          Option.map Inference_utils.sanitize_text_utf8 req.config.system_prompt
      }
  ; messages = Inference_utils.sanitize_messages_utf8 req.messages
  ; runtime_mcp_policy =
      Option.map sanitize_runtime_mcp_policy_for_cli req.runtime_mcp_policy
  }
;;

let make_cli_argv_sanitizing_transport (transport : Llm_provider.Llm_transport.t) =
  { Llm_provider.Llm_transport.complete_sync =
      (fun req -> transport.complete_sync (sanitize_cli_completion_request_for_argv req))
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event req ->
         transport.complete_stream ~on_event (sanitize_cli_completion_request_for_argv req))
  }
;;
