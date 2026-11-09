(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy shared by
    the HTTP response path and machine checkpoints. *)

(** {1 Types} *)

type compress_result =
  | Unchanged of string
  | Compressed of string  (** zstd-encoded payload. *)

(** {1 Thresholds} *)

val min_size : int
(** Minimum payload size (bytes) below which compression is skipped. *)

(** {1 Encoding} *)

val content_encoding : string
(** HTTP [Content-Encoding] header value for a [Compressed] payload. *)

(** {1 Compression} *)

val compress : ?level:int -> string -> compress_result
(** [compress ?level data] compresses [data] with zstd at [level] (default 3).
    Returns [Unchanged] when the payload is smaller than {!min_size} or when
    compression does not reduce the size. Zstd failures are logged and
    surfaced as [Unchanged]. *)

val decompress : orig_size:int -> string -> (string, string) Stdlib.result
(** [decompress ~orig_size data] attempts to decompress [data] into a buffer of
    [orig_size] bytes. Returns [Error msg] on zstd failure. *)
