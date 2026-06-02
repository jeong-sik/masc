(** Server_routes_http_routes_artifacts — HTTP surface for the
    tool blob store.

    Tool outputs externalised by [Tool_bridge.maybe_externalize]
    live in [${MASC_BASE_PATH}/.masc/tool_blobs/<sha[0..1]>/<sha>];
    the dashboard UI displays the sentinel-marker preview by
    default and lazy-fetches the full bytes via:

    {v GET /api/v1/artifacts/<sha256> v}

    Response (200): JSON envelope
    {[
      { "sha256": ..., "bytes": <int>, "mime": "text/plain",
        "content": "<the bytes>" }
    ]}

    Errors:
    - 400 — malformed sha256 (not 64 hex chars)
    - 404 — sha256 not in store
    - 503 — base path unresolvable (store unavailable) *)

val is_valid_sha256 : string -> bool
(** [true] iff [s] is exactly 64 chars long and every char is in
    the lower / upper hex range ([0-9a-fA-F]). The route handler
    rejects requests whose path parameter fails this check with
    400 before touching the blob store, so the validation
    surfaces as a contract guard for path-traversal and
    fixed-length sentinels. *)

val blob_response :
  sha256:string ->
  Yojson.Safe.t * Httpun.Status.t
(** Look up [sha256] in the on-disk blob store
    ([${MASC_BASE_PATH}/.masc/tool_blobs/]) and return the
    JSON envelope plus the HTTP status code:

    - [`OK] when the blob is present (envelope contains the
      [content] bytes verbatim);
    - [`Not_found] when the sha is well-formed but absent
      from the store;
    - [`Service_unavailable] when [Env_config_core.base_path_opt]
      returns [None] (no [MASC_BASE_PATH], no store root).

    The function never raises — every failure path produces a
    JSON envelope with an [error] field. *)

val add_routes :
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
(** Register the [GET /api/v1/artifacts/<sha256>] route on
    [router] using {!Server_auth.with_public_read} (the
    artifacts endpoint is public-read by design — sentinel
    sha256 values do not leak in the dashboard's preview, so
    full-byte fetch needs no auth). Returns the augmented
    router. *)
