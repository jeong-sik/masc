(** Unified Attachment Store HTTP surface.

    Endpoints (HTTP/1.1 & HTTP/2):
    - [POST /api/v1/attachments] ([CanBroadcast]): accepts raw binary body
      ([Content-Type], optional [X-Filename], [X-Retention], [X-Keeper],
      [X-Origin]) or [multipart/form-data] with a [file] part. Returns
      [201 Created] [{ "ok": true, "data": <meta_wire_json> }].
    - [GET /api/v1/attachments/<id>] and [HEAD /api/v1/attachments/<id>]
      ([CanReadState]): serves verified binary bytes with [Content-Type],
      [X-Content-Type-Options: nosniff],
      [Content-Security-Policy: default-src 'none'; sandbox],
      [ETag: "<sha256>"], [Cache-Control: private, max-age=31536000, immutable],
      conditional [If-None-Match] -> [304 Not Modified], optional
      [?download=1], [?format=png], and [?max_px=N] (clamped [32..2048]).
    - [GET /api/v1/attachments/<id>/meta] ([CanReadState]): returns
      [200 OK] [{ "ok": true, "data": <meta_wire_json> }]. *)

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
