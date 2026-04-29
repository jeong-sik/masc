(** Transport_read_model — typed model of the HTTP transport's
    advertised endpoints.

    Single source of truth for "what URL should clients connect
    to", consolidating env-var resolution + loopback-host
    canonicalisation + base-URL trailing-slash hygiene.  The
    JSON projections drive the [masc_status] transport block
    and the dashboard's connection-info card.

    All hostname / IP / URI manipulation helpers stay private —
    operator-visible surface is the {!http_context} record + its
    constructors + the two JSON projections. *)

(** {1 HTTP context} *)

type http_context = {
  base_url : string;
  host : string;
  allow_legacy_accept : bool;
  include_configured : bool;
}
(** Concrete record because callers
    ({!Server_routes_http_runtime},
    {!Tool_misc_transport}) field-access [base_url] / [host]
    when composing operator-visible URLs.

    Field invariants enforced by every constructor:
    - [base_url] has trailing slashes stripped
      (single-pass; runs on every binding/handshake).
    - [host] is canonicalised through
      {!normalize_advertised_host}.
    - [allow_legacy_accept] mirrors the
      [MASC_ALLOW_LEGACY_ACCEPT] gate so the JSON projection
      can advertise legacy-mode availability.
    - [include_configured] toggles whether
      [(configured: <bool>)] sub-fields appear in the
      [transport_status_json] output (operator-only flag — UI
      never sets it). *)

val normalize_advertised_host : string -> string
(** [normalize_advertised_host host] returns the trimmed
    [host], unless it is one of the loopback aliases — in
    which case it returns
    {!Masc_network_defaults.masc_http_default_host}.

    {2 Loopback alias set}

    | Input | Treated as loopback |
    |---|---|
    | unspecified IPv4 (`0.0.0.0`) | yes |
    | unspecified IPv6 (`::`) | yes |
    | `127.0.0.1` (and any `127.x.x.x`) | yes |
    | IPv6 `::1` | yes |
    | string `"localhost"` (case-insensitive) | yes |
    | other | no |

    Pinning the alias set at the contract seam: a future
    "treat 127.0.0.1:8935 differently from 0.0.0.0:8935" PR
    must touch this explicitly so dashboard URLs do not break. *)

val make_http_context :
  ?include_configured:bool ->
  base_url:string ->
  host:string ->
  allow_legacy_accept:bool ->
  unit ->
  http_context
(** [make_http_context ?include_configured ~base_url ~host
    ~allow_legacy_accept ()] returns a context with [base_url]
    normalised through {!normalize_loopback_base_url} (private,
    delegates to {!normalize_advertised_host} for host
    component + trailing-slash strip) and [host] normalised
    through {!normalize_advertised_host}.  [include_configured]
    defaults to [false]. *)

val context_from_env :
  ?include_configured:bool ->
  allow_legacy_accept:bool ->
  unit ->
  http_context
(** [context_from_env ?include_configured ~allow_legacy_accept ()]
    builds a context from the runtime environment:

    1. Default host from {!Env_config_core.masc_host} (then
       canonicalised).
    2. Default base URL [http://<host>:<port>] using
       {!Env_config_core.masc_http_port_int}.
    3. If {!Env_config_core.http_base_url_env_key} env var is
       set to a non-empty value, override the base URL with it
       (then re-normalise).
    4. The [host] field is re-extracted from the final
       [base_url] so a custom env-var URL like
       [http://example.com:8000/] propagates correctly into
       JSON output. *)

(** {1 JSON projections} *)

val websocket_discovery_json : http_context -> Yojson.Safe.t
(** [websocket_discovery_json ctx] returns the WebSocket
    discovery payload used by browser dashboards to learn the
    [ws://]/[wss://] URL.  Includes the configured-port +
    runtime-listening fields when [ctx.include_configured] is
    [true]. *)

val transport_status_json : http_context -> Yojson.Safe.t
(** [transport_status_json ctx] returns the full transport
    status JSON (HTTP + WebSocket + protocol set), used by
    [masc_status] / dashboard / [transport_status] tool.

    Includes [configured: <bool>] sub-fields when
    [ctx.include_configured] is [true] — this is the operator-
    only diagnostics path that reveals enable/disable state
    via env-var, distinct from the runtime listening state.
    Default ([false]) hides the configured fields so dashboard
    UI does not leak operator-only knobs. *)
