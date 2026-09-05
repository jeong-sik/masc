(** Network default constants — SSOT for ports and URLs.

    All hardcoded network defaults live here. Other modules reference
    these constants instead of inlining magic strings/numbers.

    The [local_llm_default_url] follows the same env override chain that AGENT_CORE
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
    matches what the Agent Core's own [api_openai.ml] uses internally. *)
let chat_completions_path = "/chat/completions"

(** Default URL for Ollama. *)
let ollama_default_url =
  Printf.sprintf "http://127.0.0.1:%d" ollama_default_port

(** Ollama native API path for the running-models ("process status")
    endpoint.  Used by both {!Runtime_http_probe} (runtime-level
    capacity probe) and {!Tool_local_runtime_probe} (tool-level KV
    assessment); anchoring the suffix in one place prevents the two
    call sites from drifting if Ollama ever renames the route. *)
let ollama_api_ps_path = "/api/ps"

(** Ollama native API path for text generation.  Used by the
    tool-level probe path that exercises a model end-to-end. *)
let ollama_api_generate_path = "/api/generate"

(** Default URL for the local OpenAI-compatible runtime.
    Override order: AGENT_CORE_LOCAL_LLM_URL -> local runtime. *)
let local_llm_default_url =
  match nonempty_env "AGENT_CORE_LOCAL_LLM_URL" with
  | Some value -> value
  | None -> ollama_default_url

(** Default port for the MASC HTTP server. *)
let masc_http_default_port = 8935

(** Default port as string (for env config fallback). *)
let masc_http_default_port_s =
  string_of_int masc_http_default_port

(** Default host for the MASC HTTP server. *)
let masc_http_default_host = "127.0.0.1"

(* The address a client on this machine dials to reach that server.

   The same string as the bind default today, and a different question. A
   bind address answers "which interfaces do I accept on" and may be a
   wildcard -- [is_unspecified_host] exists because 0.0.0.0 and :: mean
   "every interface" rather than a reachable peer, and dialing one is not
   reaching the server that bound it. Sharing one name for both let a client
   read the server's bind setting as its destination. *)
let masc_http_loopback_peer = "127.0.0.1"

(* Lives here rather than at the reader so [Env_config_snapshot] can name it
   instead of restating the number. Restating is how the operator surface came
   to report 128 while the server accepted 512 (#14143 raised the reader and
   left the snapshot). [Masc_network_defaults] is in the config layer, which
   the snapshot can reference and [Http_server_eio] cannot be. *)

(** Default concurrent-connection ceiling for the MASC HTTP server. *)
let masc_http_default_max_connections = 512

(** String form of {!masc_http_default_max_connections} for the env snapshot. *)
let masc_http_default_max_connections_s = string_of_int masc_http_default_max_connections

(** [is_loopback_host host] returns [true] when [host] resolves to any
    IPv4/IPv6 loopback address (via {!Ipaddr}).  Treats the literal
    "localhost" (after trim + lowercase) as loopback.  Malformed
    addresses return [false] — unlike a plain string prefix match,
    which would wrongly accept garbage like "127.invalid".

    "Any" means the whole of 127.0.0.0/8, which is what RFC 1122 §3.2.1.3
    reserves. This used to compare against 127.0.0.1 alone while saying
    otherwise, so 127.0.0.2 and systemd-resolved's 127.0.0.53 read as remote
    on the one implementation three others already treated as loopback
    (#27576). Traffic addressed anywhere in 127/8 cannot leave the host,
    which is what the callers are asking about.

    An IPv4-mapped IPv6 address (::ffff:127.0.0.1) is the same address
    arriving over a dual-stack socket; every implementation missed it. *)
let is_loopback_host host =
  let normalized = String.trim host |> String.lowercase_ascii in
  match normalized with
  | "localhost" -> true
  | _ -> (
      match Ipaddr.of_string normalized with
      | Ok ip -> (
          match ip with
          | Ipaddr.V4 addr -> Ipaddr.V4.Prefix.(mem addr loopback)
          | Ipaddr.V6 addr -> (
              match Ipaddr.v4_of_v6 addr with
              | Some mapped -> Ipaddr.V4.Prefix.(mem mapped loopback)
              | None -> Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0))
      | Error _ -> false)

(** Convenience wrapper for [Uri.host]-style inputs.  Returns [false]
    when the host is absent. *)
let is_loopback_host_opt = function
  | Some host -> is_loopback_host host
  | None -> false

(** [is_unspecified_host host] returns [true] for the wildcard bind addresses
    0.0.0.0 and ::, which mean "every interface" rather than a reachable peer.
    Callers ask this to tell an advertised address apart from a bind address.

    Three modules carried a byte-identical copy of this before (#27219);
    unspecified and loopback are decided in the same place because the callers
    that ask one almost always ask the other. *)
let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok (Ipaddr.V4 addr) -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ok (Ipaddr.V6 addr) -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0
  | Error _ -> false

(* Sole owner of URL-shaped trailing-slash trimming. This is the lowest
   layer that needs it ([Env_config_core] depends on this module, not the
   other way round), so callers above reach it here instead of keeping a
   copy.

   [""] and ["/"] both become [""]. Paths, where ["/"] is the root and must
   survive, use [Env_config_core.strip_path_trailing_slashes] instead — a
   different function because it is a different rule, not a variant of this
   one.

   Scans the index once and calls [String.sub] at most once, so a value
   ending in many slashes does not allocate one string per slash. *)
let trim_trailing_slashes value =
  let len = String.length value in
  let rec last_non_slash i =
    if i < 0 || value.[i] <> '/' then i else last_non_slash (i - 1)
  in
  let last = last_non_slash (len - 1) in
  if last = len - 1 then value else String.sub value 0 (last + 1)

(** [normalize_advertised_host host] answers "what should a client dial?" for
    a host that may have been written as a bind setting.

    Rewrites two kinds of address to {!masc_http_default_host}:

    - the wildcards 0.0.0.0 and :: ({!is_unspecified_host}), which name every
      interface rather than a peer anyone can reach back on;
    - the two loopback spellings that some client libraries resolve to an
      IPv6-only socket: ["localhost"] and [::1].

    Every other host is returned trimmed, {b including the rest of
    127.0.0.0/8}. That is deliberately narrower than {!is_loopback_host},
    which accepts the whole /8: an operator who writes 127.0.1.1 picked one
    interface out of that range and keeps it. Widening this to
    [is_loopback_host] would rewrite that choice without saying so. *)
let normalize_advertised_host host =
  let trimmed = String.trim host in
  if is_unspecified_host trimmed then masc_http_default_host
  else
    match String.lowercase_ascii trimmed with
    | "localhost" -> masc_http_default_host
    | normalized -> (
        match Ipaddr.of_string normalized with
        | Ok (Ipaddr.V6 addr) when Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0
          ->
            masc_http_default_host
        | Ok (Ipaddr.V6 _ | Ipaddr.V4 _) | Error _ -> trimmed)

(* The prefix of the route that serves a synthesized voice clip.

   Named because two of the places that spell it have to agree, and they live
   in different files: [Server_routes_http_routes_voice] registers the route
   under this prefix, and [Server_auth] lists the same prefix as publicly
   readable. A browser's <audio> element cannot put a bearer token in its
   request headers, so the unguessable filename token is the capability. If
   the two spellings drift, one direction breaks playback under strict auth
   and the other opens a path nobody meant to expose. Five more places build
   a URL from it. *)
let voice_audio_path_prefix = "/api/v1/voice/audio/"

(* The server-relative path a client fetches for the clip named by [token]. *)
let voice_audio_path token = voice_audio_path_prefix ^ token

let normalize_loopback_base_url base_url =
  let trimmed = String.trim base_url |> trim_trailing_slashes in
  let uri = Uri.of_string trimmed in
  match Uri.host uri with
  | Some host ->
      let normalized_host = normalize_advertised_host host in
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
