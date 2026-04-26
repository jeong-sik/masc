(** Backend_compression — ZSTD header framing for the backend.

    Currently a passthrough: compression is disabled because the
    4TB SSD makes ZSTD savings negligible and corrupt ZSTD headers
    in PG caused server-wide decompress storms (2026-03-28). The
    public API is preserved so callers need no changes. *)

(** {1 Constants} *)

val min_size : int
val default_level : int

(** {1 Low-level primitives} *)

(** [compress ?level data] returns [(compressed, used_dict, did_compress)].
    When [did_compress = false] the returned [compressed] equals
    [data] (input was below the compression threshold). *)
val compress : ?level:int -> string -> string * bool * bool

(** [decompress ~orig_size ~used_dict compressed] returns
    [Some plaintext] on success, [None] on decompression error
    (logged via [Log.Misc.error]). *)
val decompress : orig_size:int -> used_dict:bool -> string -> string option

(** {1 Header framing}

    Public because benchmarks / coverage tests assemble frames
    manually. *)

(** [encode_with_header ~used_dict orig_size compressed] prepends a
    9-byte [ZSTD] / [ZSTDD] header to [compressed]. *)
val encode_with_header : used_dict:bool -> int -> string -> string

(** [decode_header data] returns [Some (orig_size, compressed, used_dict)]
    when [data] starts with a recognised header, else [None]. *)
val decode_header : string -> (int * string * bool) option

(** {1 Framed entry points} *)

(** Auto-decompress if a [ZSTD] / [ZSTDD] header is present; return
    [data] unchanged otherwise. On decompression failure, returns
    the original [data] (logged via [Log.Misc.error]). *)
val decompress_auto : string -> string

(** Compress and prepend a header if beneficial. Currently a
    passthrough — returns [data] unchanged regardless of [level]. *)
val compress_with_header : ?level:int -> string -> string
