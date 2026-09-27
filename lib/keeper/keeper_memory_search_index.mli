(** Lexical ranking of memory texts for [keeper_memory_search]
    (RFC-memory-search-beyond-substring section 3.1).

    Each call builds a private in-memory SQLite FTS5 table over the texts it
    is given, asks it for every text holding any whitespace-separated term of
    the query, and drops the table. SQLite owns tokenization (the [trigram]
    tokenizer: case-insensitive substrings of three or more characters, so a
    Korean suffix does not hide a stem) and BM25 ranking; this module adds no
    stop-word, stemming, regular-expression, or intent rules. There is no
    persistent index, so nothing can disagree with the memory store.

    A term shorter than three characters matches no text through the trigram
    tokenizer. It is quoted into the query like any other term and simply
    contributes nothing; the caller's substring tiers still answer it. *)

type error = Index_unavailable of string

val error_to_string : error -> string

val rank : query:string -> string list -> ((int * float) list, error) result
(** [rank ~query texts] is the positions in [texts] of the texts holding any
    term of [query], best first, each with its BM25 score (lower is better;
    ties keep input order). A query with no term ranks nothing. *)
