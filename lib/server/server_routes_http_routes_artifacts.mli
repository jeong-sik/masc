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
    - 413 — artifact exceeds the 32 MiB whole-response limit
    - 503 — stored artifact unreadable

    Uploads arrive as raw bytes (board file sharing):

    {v POST /api/v1/artifacts v}

    The request body is the stored bytes. Its [Content-Type] is not read: the
    store keeps bytes under their digest and nothing else.

    Response (201): JSON envelope
    {[
      { "sha256": ..., "bytes": <int> }
    ]}

    Errors:
    - 400 — empty body, or a body shorter than its Content-Length
    - 401/403 — missing or under-privileged credential
    - 413 — body above the 32 MiB artifact limit (the upload reads against
      this limit, not the general request cap)
    - 500 — durable write failed

    The JSON routes ([GET /api/v1/artifacts/<sha256>] and this upload) are
    HTTP/1 only; the H2 gateway serves only the raw-bytes
    [GET /api/v1/artifact-bytes/<sha256>]. *)

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

    Oversized artifacts return [`Payload_too_large]. Store inspection, read,
    and integrity failures return [`Service_unavailable]. Cancellation
    propagates. *)

val artifact_read_permission : Masc_domain.permission
(** Operator-only authority required to dereference exact tool-output bytes. *)

val maximum_artifact_response_bytes : int
(** Upper bound for either whole-body HTTP artifact response. *)

val too_large_response : int -> int -> Yojson.Safe.t
(** Typed JSON body for an artifact exceeding the HTTP response bound. *)

val artifact_bytes :
  base_path:string ->
  sha256:string ->
  (string option, Tool_blob_store.fetch_error) result
(** Exact validated bytes shared by the HTTP/1 and HTTP/2 authenticated raw
    download routes. The blocking file read runs in an Eio system thread and
    rejects files above {!maximum_artifact_response_bytes} before allocating
    their full content. *)

type upload_refusal =
  | Empty_upload
  | Truncated_upload of { declared : int; received : int }
  | Upload_too_large of { maximum : int }
  | Upload_store_failed

val store_upload :
  base_path:string ->
  declared:int option ->
  bytes:string ->
  (Tool_output.artifact_ref, upload_refusal) result
(** Durably persist one uploaded body under its content address.
    [declared] is the request's Content-Length when it carried one: a body
    of another length was cut short and is refused, as is an empty one, so
    nothing but a whole file is stored. Cancellation propagates. *)

val add_routes :
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
(** Register the [GET /api/v1/artifacts/<sha256>] route on
    [router], plus binary-safe [GET /api/v1/artifact-bytes/<sha256>] and the
    [POST /api/v1/artifacts] upload route. Exact bytes require a token-bound operator credential even when
    general HTTP auth is non-strict; a content digest is not an authorization
    capability. Returns the augmented router. *)
