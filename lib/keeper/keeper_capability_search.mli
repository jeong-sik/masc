(** Structured lexical search over one already-authorized Keeper capability
    catalog. SQLite FTS5 owns tokenization and BM25 ranking; this module adds
    no stop-word, substring, regular-expression, or intent heuristics. *)

type 'a document =
  { payload : 'a
  ; name : string
  ; description : string
  ; invocation_name : string option
  }

type 'a hit =
  { document : 'a document
  ; bm25 : float
  }

type error =
  | Empty_query
  | Frozen_surface_required
  | Index_unavailable of string
  | Invalid_query of string

val search : query:string -> 'a document list -> ('a hit list, error) result
val error_to_yojson : error -> Yojson.Safe.t
