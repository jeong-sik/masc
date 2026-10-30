(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy so transport
    and backend layers depend on a neutral codec rather than backend-local
    helpers. *)

(** {1 Types} *)

type encoding =
  | Standard
  | Dictionary

type compressed = {
  payload : string;
  encoding : encoding;
}

type compress_result =
  | Unchanged of string
  | Compressed of compressed

(** {1 Thresholds} *)

val min_size : int
(** Minimum payload size (bytes) below which compression is skipped. *)

(** {1 Encoding helpers} *)

val uses_dict : encoding -> bool

val content_encoding : encoding -> string
(** HTTP [Content-Encoding] header value for an [encoding]. *)

(** {1 Compression} *)

val compress : ?level:int -> string -> compress_result
(** [compress ?level data] compresses [data] with zstd at [level] (default 3).
    Returns [Unchanged] when the payload is smaller than {!min_size} or when
    compression does not reduce the size. Zstd failures are logged and
    surfaced as [Unchanged]. *)

val decompress : orig_size:int -> string -> (string, string) Stdlib.result
(** [decompress ~orig_size data] attempts to decompress [data] into a buffer of
    [orig_size] bytes. Returns [Error msg] on zstd failure. *)
