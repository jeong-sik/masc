(** Byte-wise string helpers shared by every agent_core layer.

    Deliberately free of [Str]: that library keeps its match state in globals,
    which is unsound under the fibers this code runs in, and it recompiles a
    pattern on every call. These do neither. *)

val contains_substring : haystack:string -> needle:string -> bool
(** [true] for an empty needle, matching the convention the copies this
    replaced already followed. *)

val contains_substring_ci : haystack:string -> needle:string -> bool
(** ASCII case-insensitive. Bytes outside ASCII compare unchanged. *)

val utf8_prefix : max_bytes:int -> string -> string
(** At most [max_bytes] bytes of the string, cut at a UTF-8 character boundary
    so a multi-byte character is never split. [""] when [max_bytes <= 0]. A
    string that fits comes back unchanged. Invalid UTF-8 is cut on a
    best-effort basis: complete ASCII bytes stay, an incomplete lead byte is
    dropped. *)
