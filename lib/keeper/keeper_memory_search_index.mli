(** Lexical ranking of memory texts for [keeper_memory_search].

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

    A term shorter than three UTF-8 characters falls back to SQL [LIKE] candidate
    filtering paired with {!String_util.contains_query_term_ci}: short ASCII word
    terms (1–2 alphanumeric characters) enforce ASCII word boundaries (so [RC]
    matches [RC는] and [RC-12] while excluding [source]/[SRC], and [no] excludes
    [astronomy]), while short non-ASCII or punctuated terms keep case-insensitive
    substring matching. *)

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

val with_excluding_owners
  :  texts:(string * string) list
  -> max_results:int
  -> (rank:((string * string) list -> ((int * float) list list, error) result) -> 'a)
  -> 'a * batch_stats
(** One transient table over [texts] for several rankings. [f ~rank] may call
    [rank queries] any number of times; each answers like
    {!rank_many_excluding_owners}. The table is built once, on the first
    [rank] with work, and closed when [f] returns or raises. The stats count
    that build and every query any [rank] ran. Each build and each [rank] is
    one job on the process domain pool when the caller is an Eio fiber, and
    the jobs never overlap; [f] itself runs in the caller's thread. *)

(** {1 Persistent Per-Keeper SQLite WAL FTS5 Index}

    Each Keeper owns [<keepers_dir>/<keeper_id>.memory_fts.db] in SQLite WAL
    mode, accessed strictly off the main Eio domain via
    {!Domain_pool_ref.submit_io_or_inline}. Concurrent readers never block
    writers or sibling Keepers, and unchanged snapshots skip rebuilding. *)

type persistent_hit =
  { memory_id : string
  ; claim : string
  ; category : string
  ; score : float
  }

val db_suffix : string
val db_path : keepers_dir:string -> keeper_id:string -> string

(** Synchronize the persistent per-Keeper SQLite WAL FTS5 index with [snapshot].
    Skips rebuild when the stored [(revision, content_sha256)] already matches.
    Returns the number of indexed facts. *)
val sync_snapshot
  :  keepers_dir:string
  -> keeper_id:string
  -> Keeper_memory_os_current_types.t
  -> (int, error) result

(** Query the persistent per-Keeper SQLite WAL FTS5 index directly off-domain.
    Returns matching facts ordered by BM25 score (best first). *)
val search_persistent
  :  keepers_dir:string
  -> keeper_id:string
  -> query:string
  -> limit:int
  -> (persistent_hit list, error) result

(** Sync-if-needed and rank [facts] against the persistent per-Keeper SQLite
    WAL FTS5 index, returning [(ordinal, score)] pairs aligned to [facts]. *)
val rank_persistent_for_facts
  :  keepers_dir:string
  -> keeper_id:string
  -> query:string
  -> Keeper_memory_os_types.fact list
  -> ((int * float) list, error) result
