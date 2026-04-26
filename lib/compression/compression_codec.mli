(** Shared compression codec surface.

    This module owns the raw zstd compression/decompression policy so transport
    and backend layers depend on a neutral codec rather than backend-local
    helpers. *)

(** {1 Types} *)

type encoding =
  | Standard
  | Dictionary

type compressed =
  { payload : string
  ; encoding : encoding
  }

type compress_result =
  | Unchanged of string
  | Compressed of compressed

(** {1 Thresholds} *)

(** Minimum payload size (bytes) below which compression is skipped. *)
val min_size : int

(** Upper bound reserved for dictionary payloads. *)
val max_dict_size : int

(** {1 Encoding helpers} *)

(** [should_use_dict size] returns whether a payload of [size] bytes should be
    routed through the dictionary-aware path. Currently a simple size floor. *)
val should_use_dict : int -> bool

(** Current dictionary bytes. Empty string when no dictionary is loaded. *)
val get_dict : unit -> string

val has_dict : unit -> bool
val uses_dict : encoding -> bool
val of_used_dict : bool -> encoding

(** HTTP [Content-Encoding] header value for an [encoding]. *)
val content_encoding : encoding -> string

(** {1 Compression} *)

(** [compress ?level data] compresses [data] with zstd at [level] (default 3).
    Returns [Unchanged] when the payload is smaller than {!min_size} or when
    compression does not reduce the size. Zstd failures are logged and
    surfaced as [Unchanged]. *)
val compress : ?level:int -> string -> compress_result

(** [decompress ~orig_size ~encoding data] attempts to decompress [data] into a
    buffer of [orig_size] bytes. Returns [Error msg] on zstd failure. *)
val decompress
  :  orig_size:int
  -> encoding:encoding
  -> string
  -> (string, string) Stdlib.result
