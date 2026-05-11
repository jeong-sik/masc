(** Server_mcp_transport_http_sse — Thin compatibility wrapper
    over the HTTP SSE connection registry.

    Historical context: cleanup loops read this module while
    request handlers mutated
    {!Server_mcp_transport_http_conn}.  This wrapper re-exports
    the conn implementation so both paths observe the same
    registry + guard tables.  Drift in either direction would
    re-introduce the registry split that previously caused
    cleanup-vs-mutation race conditions.

    The .ml is 13 lines:
    - [type deps = Server_mcp_transport_http_types.deps] alias
    - [include Server_mcp_transport_http_conn]
    - [respond_sse_rate_limited] re-export from
      {!Server_mcp_transport_http_respond}.

    This .mli mirrors with type-identity-preserving cascade
    (see cycle 187 [coord_utils.mli] for the [module type of
    struct include M end] pattern rationale). *)

type deps = Server_mcp_transport_http_types.deps
(** Per-request dependency bundle.  Aliased from
    {!Server_mcp_transport_http_types.deps} — type identity
    preserved so callers can interleave the two names. *)

include module type of struct
  include Server_mcp_transport_http_conn
end
(** Re-exposes the entire connection registry surface
    (registry / guard / session tracking) used by both cleanup
    loops and request handlers.  Type identity preserved end-
    to-end via the [struct include M end] form. *)

val respond_sse_rate_limited :
  deps:Server_mcp_transport_http_types.deps ->
  origin:string ->
  session_id:string ->
  protocol_version:string ->
  reason:Sse_reject_reason.t ->
  retry_after_s:float ->
  Httpun.Reqd.t ->
  unit
(** Pinned alias of
    {!Server_mcp_transport_http_respond.respond_sse_rate_limited}
    at the SSE wrapper boundary so call-sites that historically
    reached the helper through this module continue to work
    without import churn.  Signature mirrors the source mli
    exactly — labeled args [~deps], [~origin], [~session_id],
    [~protocol_version], [~reason], [~retry_after_s]. *)
