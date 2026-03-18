(** LLM response cache (L1 memory + L2 .masc/cache).

    This module stores provider/model-aware response payloads as JSON blobs.
    It is intentionally generic so callers can serialize/deserialize their
    own response types. *)

type l1_stats = {
  entries : int;
  max_entries : int;
}

(** Enable Eio-aware locking for L1 cache operations.
    Should be called once from Eio runtime startup. *)
val enable_eio : unit -> unit

(** Build a deterministic cache key with SHA256.
    Example output: ["llmresp:ab12..."] *)
val make_key : namespace:string -> content:string -> string

(** Read JSON payload by cache key.
    Returns [Ok None] on miss/expired entries. *)
val get_json : key:string -> (Yojson.Safe.t option, string) result

(** Write JSON payload by cache key.
    [ttl_seconds] defaults to [MASC_LLM_CACHE_TTL_SEC]. *)
val set_json :
  key:string ->
  ?ttl_seconds:int ->
  Yojson.Safe.t ->
  (unit, string) result

(** Delete a key from both L1 and L2 cache. *)
val delete : key:string -> (unit, string) result

(** Reset in-memory L1 cache. Useful for tests. *)
val clear_l1 : unit -> unit

(** Current L1 cache stats. *)
val get_l1_stats : unit -> l1_stats
