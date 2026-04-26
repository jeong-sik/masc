(** Cache_eio — file-based cache with TTL and tags.

    Filesystem-backed key-value cache with expiration, tag filtering,
    and batch eviction.

    @since 0.1.0 *)

(** {1 Types} *)

type cache_entry =
  { key : string
  ; value : string
  ; created_at : float
  ; expires_at : float option
  ; tags : string list
  }

(** {1 Configuration} *)

val eviction_sample_threshold : float
val batch_eviction_interval : float

(** {1 Paths} *)

val cache_dir : Coord_utils.config -> string
val ensure_cache_dir : Coord_utils.config -> unit
val sanitize_key : string -> string
val cache_filename : string -> string

(** {1 Serialization} *)

val entry_to_json : cache_entry -> Yojson.Safe.t
val entry_of_json : Yojson.Safe.t -> cache_entry option

(** {1 Core Operations} *)

val set
  :  Coord_utils.config
  -> key:string
  -> value:string
  -> ?ttl_seconds:int
  -> ?tags:string list
  -> unit
  -> (cache_entry, string) result

val get : Coord_utils.config -> key:string -> (cache_entry option, string) result
val delete : Coord_utils.config -> key:string -> (bool, string) result
val list : Coord_utils.config -> ?tag:string -> unit -> cache_entry list
val clear : Coord_utils.config -> (int, string) result
val stats : Coord_utils.config -> (int * int * float, string) result
val format_stats : int * int * float -> string

(** {1 Eviction} *)

val evict_expired : Coord_utils.config -> int
val maybe_evict_expired : Coord_utils.config -> int
val count_entries : Coord_utils.config -> int
val is_expired : cache_entry -> bool
val last_batch_eviction : float Atomic.t
val cached_entry_count : int Atomic.t
val reset_cached_entry_count : unit -> unit
