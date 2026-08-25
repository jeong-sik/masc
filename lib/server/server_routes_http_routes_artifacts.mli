(** Server_routes_http_routes_artifacts — HTTP surface for the
    tool blob store.

    Tool outputs externalised by [Tool_bridge.maybe_externalize]
    live in [<workspace-base-path>/.masc/tool_blobs/<sha[0..1]>/<sha>];
    the dashboard UI displays the marker preview by
    default and lazy-fetches the full bytes via:

    {v GET /api/v1/artifacts/<sha256> v}

    Response (200): JSON envelope
    {[
      { "sha256": ..., "bytes": <int>, "mime": "text/plain",
        "content": "<the bytes>" }
    ]}

    Errors:
    - 400 — malformed sha256 (not 64 lowercase hex chars)
    - 404 — sha256 not in store
    - 503 — stored artifact unreadable *)

val is_valid_sha256 : string -> bool
(** Shared exact lowercase SHA-256 validation used by the route guard. *)

val blob_response :
  base_path:string -> sha256:string -> Yojson.Safe.t * Httpun.Status.t
(** Look up [sha256] in the on-disk blob store
    ([<base_path>/.masc/tool_blobs/]) and return the
    JSON envelope plus the HTTP status code:

    - [`OK] when the blob is present (envelope contains the
      [content] bytes verbatim);
    - [`Not_found] when the sha is well-formed but absent
      from the store.

    Store inspection, read, and integrity failures return
    [`Service_unavailable]. Cancellation propagates. *)

val artifact_read_permission : Masc_domain.permission
(** Operator-only authority required to dereference exact tool-output bytes. *)

val add_routes :
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
(** Register the [GET /api/v1/artifacts/<sha256>] route on
    [router]. Exact bytes require a token-bound operator credential even when
    general HTTP auth is non-strict; a content digest is not an authorization
    capability. Returns the augmented router. *)
