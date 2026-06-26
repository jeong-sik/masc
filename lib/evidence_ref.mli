(** Evidence_ref — typed SSOT for reviewer-inspectable evidence references.

    Raw evidence references still enter the system as strings for wire
    compatibility, but recognition of supported shapes lives here. Gates should
    consume {!of_string} and match the typed value instead of rediscovering ref
    kinds locally. *)

type trace_kind =
  | Trace
  | Turn
  | Receipt

type t =
  | Url of string
  | File_uri of string
  | Pr of int
  | Commit of string
  | Trace_ref of trace_kind * string
  | File_path of string

val of_string : string -> t option
val to_string : t -> string
val is_concrete_string : string -> bool

val boundary_match : haystack:string -> needle:string -> start:int -> bool
(** [boundary_match ~haystack ~needle ~start] is true when [needle] appears
    as a standalone evidence-reference token at [start]. The policy treats
    path/URL/trace punctuation as extending the token only when more reference
    characters follow, so ["src/main.ml."] can end a sentence while
    ["src/main.ml.bak"] remains a longer reference. *)
