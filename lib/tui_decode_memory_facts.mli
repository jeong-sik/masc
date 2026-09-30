(** Memory fact models and listing projection; no I/O or observation state. *)

(** Whether a search has ever returned the fact. The count, the number of
    distinct UTC days and the last clock come from one list of retrieval
    times on the server, so they are all absent or all present; the decoder
    rejects a row where they disagree. *)
type memory_fact_retrieval =
  | Never_retrieved
  | Retrieved of { count : int; distinct_days : int; last_at : float }

(** What the keeper did with one fact, as the server projected it from the
    memory-events sidecar (RFC-0418): whether and how a search returned it,
    how often it was retracted, and which dropped facts it continues. No
    strength or score; the numbers are the record. *)
type memory_fact_events = {
  mfe_retrieval : memory_fact_retrieval;
  mfe_retracted_count : int;
  mfe_revised_from : string list;
}

(** A fact nothing has used yet: never retrieved, no retractions, no
    predecessors. Fixtures start here. *)
val no_memory_fact_events : memory_fact_events

(** One remembered fact from a keeper's ordinary Memory OS store. The
    category and origin are the server's closed taxonomy, carried as the
    strings it spelled them in: this side renders and groups them by exact
    equality and never classifies on its own. *)
type memory_fact = {
  mf_claim : string;
  mf_category : Keeper_memory_os_types.category;
  mf_origin : string;
  mf_first_seen : float;
  mf_last_seen : float;
  mf_memory_id : string;
  mf_events : memory_fact_events;
}

(** A fact bound to a file: it holds only while the file at [msf_path] still
    hashes to [msf_sha256]. *)
type memory_source_fact = {
  msf_claim : string;
  msf_first_seen : float;
  msf_path : string;
  msf_sha256 : string;
}

(** A source-bound fact the store dropped, and the server's reason string. *)
type memory_invalidation = {
  mi_source_path : string;
  mi_invalidated_at : float;
  mi_reason : string;
}

(** One store's reading. The server answers each store independently --
    a read error, no snapshot yet, or the snapshot -- so one failing store
    never blanks the other, and this side keeps the three states apart
    instead of collapsing them into an empty list. *)
type 'a memory_store_reading =
  | Memory_store_read_error of string
  | Memory_store_absent
  | Memory_store_present of 'a

type memory_ordinary_store = {
  mos_revision : int;
  mos_updated_at : float;
  mos_facts : memory_fact list;
}

type memory_source_store = {
  mss_revision : int;
  mss_updated_at : float;
  mss_facts : memory_source_fact list;
  mss_invalidations : memory_invalidation list;
}

type memory_fact_snapshot = {
  mfs_keeper : string;
  mfs_ordinary : memory_ordinary_store memory_store_reading;
  mfs_source : memory_source_store memory_store_reading;
  mfs_events_read_error : string option;
}

val decode_memory_fact_snapshot :
  Yojson.Safe.t -> (memory_fact_snapshot, string) result
(** Decode one keeper's fact listing served at
    [/api/v1/keepers/:name/memory-facts]. Each store object is read by which
    field it carries -- [read_error], [present]:false, or [present]:true with
    its rows -- and any other shape is a decode error, not an empty store.
    [mfs_events_read_error] keeps a sidecar read failure distinct from an empty
    event history. *)

val merge_keeper_memory_facts :
  now:float ->
  (string * (memory_fact_snapshot, string) result) list ->
  memory_fact_snapshot * string option
(** Merge per-keeper fact listings into the "all keepers" view ([mfs_keeper =
    "*"]). Each fact is tagged with its keeper. The second value names every
    keeper that could not be read -- a failed load, or a store answering
    [Memory_store_read_error] -- as ["N of M keepers not read: ..."]; [None]
    when all were read. [Memory_store_absent] is a keeper with no memory yet,
    not a failure. *)
