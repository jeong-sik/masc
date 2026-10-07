(** Lexical ranking of memory texts for [keeper_memory_search]
    (RFC-memory-search-beyond-substring section 3.1).

    Each call builds a private in-memory SQLite FTS5 table over the texts it
    is given, asks it for every text holding any whitespace-separated term of
    the query, and drops the table. SQLite owns tokenization (the [trigram]
    tokenizer: case-insensitive substrings of three or more characters, so a
    Korean suffix does not hide a stem) and BM25 ranking; this module adds no
    stop-word, stemming, regular-expression, or intent rules. There is no
    persistent index, so nothing can disagree with the memory store.

    The table is built and queried as one job on the process domain pool when
    one is installed ({!Domain_pool_ref.submit_cpu_or_inline}), so the
    caller's domain keeps running its other fibers meanwhile.

    A term shorter than three characters matches no text through the trigram
    tokenizer. It is quoted into the query like any other term and simply
    contributes nothing; the caller's substring tiers still answer it. *)

type error = Index_unavailable of string

val error_to_string : error -> string

val rank : query:string -> string list -> ((int * float) list, error) result
(** [rank ~query texts] is the positions in [texts] of the texts holding any
    term of [query], best first, each with its BM25 score (lower is better;
    ties keep input order). A query with no term ranks nothing. *)

val rank_many : queries:string list -> string list -> ((int * float) list list, error) result
(** Rank several queries against one transient FTS5 table, in query order.
    The table is built once and closed before this function returns. An empty
    query has an empty result; an index error fails the whole batch. *)

type batch_stats =
  { index_builds : int
  ; indexed_rows : int
  ; queries_executed : int
  }

val rank_many_excluding_owners
  :  queries:(string * string) list
  -> texts:(string * string) list
  -> max_results:int
  -> (((int * float) list list * batch_stats), error) result
(** [(keeper_id, claim)] in both lists. The owner filter and result bound are
    applied in SQLite before returning rows, so a Keeper with many matching
    facts cannot crowd another Keeper out of the requested neighbor count.
    [max_results = 0] and empty/blank queries build no index. The stats report
    actual table construction and insertion, including the no-work case. *)
