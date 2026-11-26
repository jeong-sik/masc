(** Pure, zero-dependency ASCII/UTF-8 text & index helpers shared across all
    [masc_tui_*] libraries (UI, stores, and screens). *)

val clamp_index : int -> int -> int
(** Clamp [idx] into [[0; len - 1]], returning [0] whenever [len <= 0]. *)

val contains_ci : needle:string -> string -> bool
(** Case-insensitive ASCII substring search. Returns [true] when [needle] is
    empty (matching store/screen filter semantics). *)

val sanitize_single_line : string -> string
(** Collapse control characters ([\n], [\r], [\t], ASCII < 32) and runs of
    spaces into single ASCII spaces, then trim leading/trailing whitespace. *)

val short_hash : ?len:int -> string -> string
(** Trim [s] and return at most [len] leading bytes (default [8]). *)
