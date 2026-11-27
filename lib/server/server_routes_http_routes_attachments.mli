(** Unified Attachment Store HTTP surface.

    Endpoints (HTTP/1.1 & HTTP/2):
    - [POST /api/v1/attachments] ([CanBroadcast]): accepts raw binary body
      ([Content-Type], optional percent-encoded [X-Filename]) or
      [multipart/form-data] with a [file] part. Public uploads ALWAYS store
      [origin = User_upload] and [retention = Durable] (untrusted client
      origin/retention/keeper headers and form fields are ignored) and never
      accept opaque binaries. Returns [201 Created]
      [{ "ok": true, "data": <meta_wire_json> }].
    - [GET /api/v1/attachments/<id>] and [HEAD /api/v1/attachments/<id>]
      ([CanReadState]): serves verified binary bytes with [Content-Type],
      [X-Content-Type-Options: nosniff],
      [Content-Security-Policy: default-src 'none'; sandbox],
      [ETag: "<sha256>"], [Cache-Control: private, max-age=31536000, immutable],
      conditional [If-None-Match] -> [304 Not Modified], optional
      [?download=1] (with RFC 5987 [filename*=UTF-8''] for non-ASCII names),
      [?format=png], and [?max_px=N] (quantized to [[160; 320; 640; 1280]]).
      Internal opaque binaries persisted via {!Attachment_store.put_opaque} are
      ALWAYS served as [application/octet-stream] with
      [Content-Disposition: attachment] (never inline).
      For [Ephemeral] attachments, [Admin] / unauthenticated-dev operators are
      permitted, while non-admin [Bearer] callers must hold an active ephemeral
      pin for the attachment ([403 Forbidden] otherwise).
    - [GET /api/v1/attachments/<id>/meta] ([CanReadState], same ephemeral scope):
      returns [200 OK] [{ "ok": true, "data": <meta_wire_json> }]. *)

val upload_permission : Masc_domain.permission
val read_permission : Masc_domain.permission

val serve_attachment_by_sha256 :
  base_path:string ->
  sha256:string ->
  Httpun.Request.t ->
  Http_reqd.t ->
  bool
(** Serve an existing attachment by bare 64-hex [sha256] if present in
    {!Attachment_store}. Returns [true] if handled (including [304 Not Modified]
    or error response for a corrupt entry), or [false] when absent so callers
    like [/api/v1/media/<token>] can fall back to legacy storage. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
