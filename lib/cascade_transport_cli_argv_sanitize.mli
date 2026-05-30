(** UTF-8 argv sanitization for CLI-driven LLM transports.

    CLI providers reject invalid UTF-8 in argv/env/payloads; these
    helpers scrub strings through [Inference_utils.sanitize_text_utf8]
    before the request crosses the transport boundary. *)

val sanitize_runtime_mcp_server_for_cli
  :  Llm_provider.Llm_transport.runtime_mcp_server
  -> Llm_provider.Llm_transport.runtime_mcp_server

val sanitize_runtime_mcp_policy_for_cli
  :  Llm_provider.Llm_transport.runtime_mcp_policy
  -> Llm_provider.Llm_transport.runtime_mcp_policy

val sanitize_cli_completion_request_for_argv
  :  Llm_provider.Llm_transport.completion_request
  -> Llm_provider.Llm_transport.completion_request

val make_cli_argv_sanitizing_transport
  :  Llm_provider.Llm_transport.t
  -> Llm_provider.Llm_transport.t
