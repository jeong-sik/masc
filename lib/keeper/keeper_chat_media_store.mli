(** Keeper_chat_media_store — content-addressed store for model-generated media.

    RFC-0301: OAS streams model-generated media as [MediaDelta { media_type; data }];
    the keeper-chat bridge persists it here and surfaces it by URL token instead of
    reducing it to a byte count. Generalizes the voice-clip token/serve pattern
    ([/api/v1/voice/audio/<token>]) to an arbitrary [media_type]. Files live under
    [<masc_dir>/media/] as [<md5-hex-token>.<ext>]; identical payloads dedup to one
    file. Served by [GET /api/v1/media/<token>] (public read). *)

(** [media_type] (IANA type from the OAS media block) -> file extension; unknown
    types fall back to ["bin"]. *)
val ext_of_media_type : string -> string

(** File extension (no leading dot) -> HTTP content-type; unknown ->
    ["application/octet-stream"]. *)
val content_type_of_ext : string -> string

(** Content-type for an on-disk media file, derived from its extension. Used by
    the serve route. *)
val content_type_of_path : string -> string

(** [true] iff [token] is a well-formed store token (32-char lowercase hex, the
    MD5 shape). Guards the serve route path parameter. *)
val valid_token : string -> bool

(** [file_path_of_token ~base_dir ~token] is the on-disk path of the stored media
    for [token], or [None] if the token is malformed, absent, or reaped. *)
val file_path_of_token : base_dir:string -> token:string -> string option

(** [persist ~base_dir ~media_type ~data] writes [data] under a content-addressed
    token and returns [(token, url)] where [url] is [/api/v1/media/<token>] — the
    reader-facing reference the bridge emits in place of the old byte count. The
    write is idempotent: identical bytes reuse the existing file. *)
val persist : base_dir:string -> media_type:string -> data:string -> string * string
