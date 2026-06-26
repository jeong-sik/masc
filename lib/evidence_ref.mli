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
val recognizes_evidence_shape : string -> bool
(** [recognizes_evidence_shape value] is true when [value] matches a known
    evidence-reference SHAPE (url / file_uri / pr / commit / trace_ref /
    file_path). It is a SHAPE HEURISTIC ONLY — it does NOT semantically
    validate that the value is a real, existing, base-path-resolved
    artifact. Callers must not read [true] as "this is concrete, trusted
    evidence"; resolve and validate against the artifact store / base path
    before gating on it. (Renamed from [is_concrete_string], #22348 review.) *)

val boundary_match : haystack:string -> needle:string -> start:int -> bool
(** [boundary_match ~haystack ~needle ~start] is true when [needle] appears
    as a standalone evidence-reference token at [start]. The policy treats
    path/URL/trace punctuation as extending the token only when more reference
    characters follow, so ["src/main.ml."] can end a sentence while
    ["src/main.ml.bak"] remains a longer reference. *)
