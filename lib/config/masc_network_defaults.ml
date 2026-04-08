(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    The [local_llm_default_url] follows the same env override chain that OAS
    discovery uses before falling back to the current local runtime URL.

    @since 2.241.0 *)

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

(** Default port for Ollama (OpenAI-compatible at /v1). *)
let ollama_default_port = 11434

(** Default URL for Ollama. *)
let ollama_default_url =
  Printf.sprintf "http://127.0.0.1:%d" ollama_default_port

(** Default URL for the local OpenAI-compatible runtime.
    Override order: OAS_LOCAL_LLM_URL -> OAS_LOCAL_QWEN_URL -> local runtime. *)
let local_llm_default_url =
  match nonempty_env "OAS_LOCAL_LLM_URL", nonempty_env "OAS_LOCAL_QWEN_URL" with
  | Some value, _ -> value
  | _, Some value -> value
  | _ -> ollama_default_url

(** Default port for the MASC HTTP server. *)
let masc_http_default_port = 8935

(** Default port as string (for env config fallback). *)
let masc_http_default_port_s =
  string_of_int masc_http_default_port

(** Default host for the MASC HTTP server. *)
let masc_http_default_host = "127.0.0.1"

(** Default port for SearXNG local search. *)
let searxng_default_port = 8888

(** Default URL for SearXNG. *)
let searxng_default_url =
  Printf.sprintf "http://localhost:%d" searxng_default_port

(** Default port for OpenTelemetry OTLP HTTP exporter. *)
let otel_default_port = 4318

(** Default URL for OpenTelemetry OTLP HTTP endpoint. *)
let otel_default_url =
  Printf.sprintf "http://localhost:%d" otel_default_port

(** Allowed origins for DNS rebinding / CORS protection.
    Update here; [server_routes_http_common.ml] reads this list. *)
let allowed_origins = [
  "http://localhost";
  "https://localhost";
  "http://127.0.0.1";
  "https://127.0.0.1";
  (* Cloudflare tunnel *)
  "https://masc.crying.pictures";
  "https://masc-dev.crying.pictures";
]
