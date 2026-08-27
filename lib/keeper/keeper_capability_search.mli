(** Structured lexical search over one already-authorized Keeper capability
    catalog. SQLite FTS5 owns tokenization and BM25 ranking; this module adds
    no stop-word, substring, regular-expression, or intent heuristics. *)

type document =
  { id : string
  ; name : string
  ; description : string
  ; category : string
  }

type hit =
  { document : document
  ; rank : float
  }

type error =
  | Empty_query
  | Index_unavailable of string
  | Invalid_query of string

val search : query:string -> document list -> (hit list, error) result
val error_to_yojson : error -> Yojson.Safe.t
