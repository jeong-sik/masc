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

val legacy_min_size : int
(** Minimum payload size (bytes) for the legacy standard-zstd path.
    The main {!min_size} floor is used by the dictionary-aware path; the
    legacy path keeps its own higher floor to avoid tiny-response overhead. *)

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

val legacy_standard_result : original:string -> compress_result -> string * bool
(** [legacy_standard_result ~original result] adapts codec results for the
    legacy [Content-Encoding: zstd] path. Standard zstd results are advertised
    as compressed; unchanged payloads and dictionary results return
    [(original_or_payload, false)] so callers cannot leak dictionary-compressed
    bytes without a matching dictionary content-encoding. *)

(** {1 Compression} *)

val compress : ?level:int -> string -> compress_result
(** [compress ?level data] compresses [data] with zstd at [level] (default 3).
    Returns [Unchanged] when the payload is smaller than {!min_size} or when
    compression does not reduce the size. Zstd failures are logged and
    surfaced as [Unchanged]. *)

val legacy_standard_result : original:string -> compress_result -> string * bool
(** [legacy_standard_result ~original result] adapts the shared codec result to
    the legacy standard-zstd HTTP surface. Dictionary-compressed results cannot
    be advertised as plain [zstd], so they return [original, false]. *)

val decompress :
  orig_size:int ->
  encoding:encoding ->
  string ->
  (string, string) Stdlib.result
(** [decompress ~orig_size ~encoding data] attempts to decompress [data] into a
    buffer of [orig_size] bytes. Returns [Error msg] on zstd failure. *)
