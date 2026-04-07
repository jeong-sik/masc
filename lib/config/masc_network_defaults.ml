(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    The [local_llm_default_url] must match
    [Llm_provider.Discovery.default_endpoint] in OAS by contract.

    @since 2.241.0 *)

(** Default port for the local llama-server (OpenAI-compatible). *)
let local_llm_default_port = 8085

(** Default URL for the local llama-server.
    Contract: must equal [Llm_provider.Discovery.default_endpoint] in OAS. *)
let local_llm_default_url =
  Printf.sprintf "http://127.0.0.1:%d" local_llm_default_port

(** Default port for Ollama (OpenAI-compatible at /v1). *)
let ollama_default_port = 11434

(** Default URL for Ollama. *)
let ollama_default_url =
  Printf.sprintf "http://127.0.0.1:%d" ollama_default_port

(** Default port for the MASC HTTP server. *)
let masc_http_default_port = 8935

(** Default port as string (for env config fallback). *)
let masc_http_default_port_s =
  string_of_int masc_http_default_port

(** Default host for the MASC HTTP server. *)
let masc_http_default_host = "127.0.0.1"
