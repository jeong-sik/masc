(** Byte-wise substring search shared by every agent_core layer.

    Deliberately free of [Str]: that library keeps its match state in globals,
    which is unsound under the fibers this code runs in, and it recompiles a
    pattern on every call. These do neither. *)

val contains_substring : haystack:string -> needle:string -> bool
(** [true] for an empty needle, matching the convention the copies this
    replaced already followed. *)

val contains_substring_ci : haystack:string -> needle:string -> bool
(** ASCII case-insensitive. Bytes outside ASCII compare unchanged. *)
