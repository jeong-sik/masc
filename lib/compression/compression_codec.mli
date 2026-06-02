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

val max_dict_size : int
(** Upper bound reserved for dictionary payloads. *)

(** {1 Encoding helpers} *)

val should_use_dict : int -> bool
(** [should_use_dict size] returns whether a payload of [size] bytes should be
    routed through the dictionary-aware path. Currently a simple size floor. *)

val get_dict : unit -> string
(** Current dictionary bytes. Empty string when no dictionary is loaded. *)

val has_dict : unit -> bool

val uses_dict : encoding -> bool
val of_used_dict : bool -> encoding

val content_encoding : encoding -> string
(** HTTP [Content-Encoding] header value for an [encoding]. *)

(** {1 Compression} *)

val compress : ?level:int -> string -> compress_result
(** [compress ?level data] compresses [data] with zstd at [level] (default 3).
    Returns [Unchanged] when the payload is smaller than {!min_size} or when
    compression does not reduce the size. Zstd failures are logged and
    surfaced as [Unchanged]. *)

val decompress :
  orig_size:int ->
  encoding:encoding ->
  string ->
  (string, string) Stdlib.result
(** [decompress ~orig_size ~encoding data] attempts to decompress [data] into a
    buffer of [orig_size] bytes. Returns [Error msg] on zstd failure. *)
