(** Compatibility facade for callers that still expect [Compression_dict].

    The actual codec lives in {!Compression_codec}; this module re-exports the
    subset of the codec surface used by legacy transport code. *)

(** {1 Size Thresholds} *)

val min_dict_size : int
val max_dict_size : int
val should_use_dict : int -> bool

(** {1 Dictionary Stubs} *)

val get_dict : unit -> string
val has_dict : unit -> bool

(** {1 Compression} *)

val compress : ?level:int -> string -> string * bool * bool
(** [compress ?level data] returns [(payload, used_dict, changed)].

    - [payload] is either the compressed bytes or the input [data] unchanged.
    - [used_dict] is [true] when the dictionary-aware encoding was applied.
    - [changed] is [true] when the payload actually differs from [data]
      (i.e. compression succeeded and reduced the size).

    Any codec failure is logged and surfaced as [(data, false, false)]. *)

val decompress : orig_size:int -> used_dict:bool -> string -> string
(** [decompress ~orig_size ~used_dict data] is the inverse of {!compress}.
    Returns the input [data] unchanged when decompression fails (the error is
    logged). *)

(** {1 Content-Encoding Headers} *)

val encoding_with_dict : string
(** HTTP [Content-Encoding] header value used when [used_dict] is [true]. *)

val encoding_standard : string
(** HTTP [Content-Encoding] header value used when [used_dict] is [false]. *)

(** {1 Version Info} *)

val version : string
val version_string : string
