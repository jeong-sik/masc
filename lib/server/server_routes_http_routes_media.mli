(** Workspace media HTTP surface ([GET /api/v1/media/<sha256>] and
    [POST /api/v1/media]).

    Serves content-addressed workspace media stored by
    {!Keeper_chat_media_store} with strong [ETag], immutable private
    [Cache-Control], [If-None-Match] [304 Not Modified] revalidation,
    [X-Content-Type-Options: nosniff], [Content-Security-Policy: default-src
    'none'; sandbox], [Content-Disposition], and [Vary] headers.

    Uploads accept raw binary raster payloads ([image/png], [image/jpeg],
    [image/gif], [image/webp]) verified against magic bytes and reject SVG/XML
    and mismatched payloads with structured [no-store] JSON error envelopes.

    Single-user routes are registered via {!add_routes}; multi-account routes
    reuse {!handle_get} and {!handle_upload} through
    {!Server_account_dashboard_bridge}. *)

type upload_refusal =
  | Empty_upload
  | Truncated_upload of
      { declared : int
      ; received : int
      }
  | Upload_too_large of
      { max_bytes : int
      ; size_bytes : int option
      }
  | Svg_not_allowed
  | Unsupported_media_type of
      { declared : string option
      ; sniffed : Keeper_chat_media_store.raster_mime option
      }
  | Mime_mismatch of
      { declared : Keeper_chat_media_store.raster_mime
      ; sniffed : Keeper_chat_media_store.raster_mime
      }
  | Media_store_failed

(** Immutable private cache policy applied to [GET /api/v1/media/<sha256>]. *)
val immutable_cache_control : string

(** Sandbox CSP header applied to [GET /api/v1/media/<sha256>]. *)
val media_csp : string

(** Pure [Content-Disposition] header for a verified media object. Raster and
    audio variants use [inline]; [Application_pdf] uses [attachment]. *)
val content_disposition_of_media :
  sha256:string -> Keeper_chat_media_store.media_mime -> string

(** Pure upload verification and atomic storage helper, exposed for direct
    truncation and error-classification unit tests. *)
val store_upload :
  base_path:string ->
  content_type:string option ->
  declared:int option ->
  bytes:string ->
  (Keeper_chat_media_store.stored_media, upload_refusal) result

(** Flat JSON success envelope for [201 Created] on [POST /api/v1/media]. *)
val stored_media_to_json : Keeper_chat_media_store.stored_media -> Yojson.Safe.t

(** Flat JSON error envelope and HTTP status for a typed {!upload_refusal}. *)
val upload_refusal_response : upload_refusal -> Yojson.Safe.t * Httpun.Status.t

(** Handle [GET /api/v1/media/<sha256>] after caller authorization has already
    run. Shared by single-user and multi-account route tables. *)
val handle_get :
  cors:(string * string) list ->
  base_path:string ->
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

(** Handle [POST /api/v1/media] after caller authorization has already run.
    Reads up to {!Keeper_chat_media_store.max_raw_bytes} directly via bounded
    body reading. Shared by single-user and multi-account route tables. *)
val handle_upload :
  cors:(string * string) list ->
  base_path:string ->
  actor:string ->
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

(** Register single-user media HTTP routes on the given router:
    - [GET /api/v1/media/<sha256>] behind [Permission CanReadState]
    - [POST /api/v1/media] behind [Token_permission CanAdmin] *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
