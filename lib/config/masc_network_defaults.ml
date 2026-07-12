(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    The [local_llm_default_url] follows the same env override chain that OAS
    discovery uses before falling back to the current local runtime URL.

    @since 2.241.0 *)

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed <> "" then Some trimmed else None
  | None -> None

(** Default port for Ollama (OpenAI-compatible at /v1). *)
let ollama_default_port = 11434

(** OpenAI-compatible API path suffixes.  Shared by every local-runtime
    client/verifier/benchmark that concatenates [base_url] with a
    well-known endpoint — anchoring the path in one place avoids drift
    if the provider ever versions the API (e.g. [/v2/...]). *)
let openai_chat_completions_path = "/v1/chat/completions"

(** Version-free chat completions path for [Provider_config.t] construction.

    When [base_url] already carries a version segment (e.g. [/v1], [/v4]),
    the request path should not repeat it — the concatenation [base_url ^
    request_path] must produce exactly one version prefix.  This constant
    matches what the OAS SDK's own [api_openai.ml] uses internally. *)
let chat_completions_path = "/chat/completions"

(** OpenAI-compatible model listing path.  See
    {!openai_chat_completions_path}. *)
let openai_models_path = "/v1/models"

(** Default URL for Ollama. *)
let ollama_default_url =
  Printf.sprintf "http://127.0.0.1:%d" ollama_default_port

(** Substring used by Ollama URL heuristics: [":<port>"].  Keeps the
    heuristic anchored to {!ollama_default_port} so changing the port
    updates every classifier in one place. *)
let ollama_port_needle =
  Printf.sprintf ":%d" ollama_default_port

(** Ollama native API path for the running-models ("process status")
    endpoint.  Used by both {!Runtime_http_probe} (runtime-level
    capacity probe) and {!Tool_local_runtime_probe} (tool-level KV
    assessment); anchoring the suffix in one place prevents the two
    call sites from drifting if Ollama ever renames the route. *)
let ollama_api_ps_path = "/api/ps"

(** Ollama native API path for text generation.  Used by the
    tool-level probe path that exercises a model end-to-end. *)
let ollama_api_generate_path = "/api/generate"

(** [is_ollama_url url] returns [true] when [url] contains
    {!ollama_port_needle}.  Permissive on scheme/host so it works for
    [http://], [https://], [127.0.0.1], [localhost], or a bare
    [host:port]. *)
let is_ollama_url url =
  let hlen = String.length url in
  let nlen = String.length ollama_port_needle in
  if nlen = 0 || nlen > hlen then false
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub url i nlen = ollama_port_needle then true
      else loop (i + 1)
    in
    loop 0

(** Transport prefix marking a CLI-backed endpoint (e.g. [cli:codex]).
    Used by capacity classifiers to distinguish CLI endpoints from HTTP
    ones. *)
let cli_transport_prefix = "cli:"

(** [is_cli_transport_url url] returns [true] when [url] starts with
    {!cli_transport_prefix}.  The check is a strict prefix match rather
    than a substring scan because [cli:] is meaningful only at the
    start of the transport string. *)
let is_cli_transport_url url =
  let plen = String.length cli_transport_prefix in
  String.length url > plen
  && String.sub url 0 plen = cli_transport_prefix

(** Default URL for the local OpenAI-compatible runtime.
    Override order: OAS_LOCAL_LLM_URL -> local runtime. *)
let local_llm_default_url =
  match nonempty_env "OAS_LOCAL_LLM_URL" with
  | Some value -> value
  | None -> ollama_default_url

(** Default port for the MASC HTTP server. *)
let masc_http_default_port = 8935

(** Default port as string (for env config fallback). *)
let masc_http_default_port_s =
  string_of_int masc_http_default_port

(** Default host for the MASC HTTP server. *)
let masc_http_default_host = "127.0.0.1"

(** [is_loopback_host host] returns [true] when [host] resolves to any
    IPv4/IPv6 loopback address (via {!Ipaddr}).  Treats the literal
    "localhost" (after trim + lowercase) as loopback.  Malformed
    addresses return [false] — unlike a plain string prefix match,
    which would wrongly accept garbage like "127.invalid". *)
let is_loopback_host host =
  let normalized = String.trim host |> String.lowercase_ascii in
  match normalized with
  | "localhost" -> true
  | _ -> (
      match Ipaddr.of_string normalized with
      | Ok ip -> (
          match ip with
          | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.localhost = 0
          | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0)
      | Error _ -> false)

(** Convenience wrapper for [Uri.host]-style inputs.  Returns [false]
    when the host is absent. *)
let is_loopback_host_opt = function
  | Some host -> is_loopback_host host
  | None -> false

let trim_trailing_slashes value =
  let len = String.length value in
  let rec last_non_slash i =
    if i < 0 || value.[i] <> '/' then i else last_non_slash (i - 1)
  in
  let last = last_non_slash (len - 1) in
  if last = len - 1 then value else String.sub value 0 (last + 1)

let normalize_loopback_host host =
  let trimmed = String.trim host in
  let normalized = String.lowercase_ascii trimmed in
  match normalized with
  | "localhost" -> masc_http_default_host
  | _ -> (
      match Ipaddr.of_string normalized with
      | Ok ip -> (
          match ip with
          | Ipaddr.V6 addr ->
              if Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0 then
                masc_http_default_host
              else trimmed
          | Ipaddr.V4 _ -> trimmed)
      | Error _ -> trimmed)

let normalize_loopback_base_url base_url =
  let trimmed = String.trim base_url |> trim_trailing_slashes in
  let uri = Uri.of_string trimmed in
  match Uri.host uri with
  | Some host ->
      let normalized_host = normalize_loopback_host host in
      if String.equal normalized_host host then trimmed
      else
        Uri.with_host uri (Some normalized_host)
        |> Uri.to_string |> trim_trailing_slashes
  | None -> trimmed

(** Default port for the dashboard's Vite dev server.  The request-authority
    boundary uses the corresponding origins below for explicit local
    cross-port development. *)
let vite_dev_default_port = 5173

(** Loopback dev-server origins for the Vite frontend on
    {!vite_dev_default_port}.  Ordered [127.0.0.1 → localhost → ::1]
    to match the historical CORS allowlist. *)
let vite_dev_default_origins =
  [
    Printf.sprintf "http://127.0.0.1:%d" vite_dev_default_port;
    Printf.sprintf "http://localhost:%d" vite_dev_default_port;
    Printf.sprintf "http://[::1]:%d" vite_dev_default_port;
  ]

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
