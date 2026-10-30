(** Cache_eio — file-based cache with TTL and tags.

    Filesystem-backed key-value cache with expiration, tag filtering,
    and batch eviction.

    @since 0.1.0 *)

(** {1 Types} *)

type cache_entry = {
  key : string;
  value : string;
  created_at : float;
  expires_at : float option;
  tags : string list;
}

(** {1 Configuration} *)

(** {1 Paths} *)

val cache_dir : Workspace_utils.config -> string
val sanitize_key : string -> string
val cache_filename : string -> string

(** {1 Serialization} *)

val entry_to_json : cache_entry -> Yojson.Safe.t

(** {1 Core Operations} *)

val set :
  Workspace_utils.config ->
  key:string ->
  value:string ->
  ?ttl_seconds:int ->
  ?tags:string list ->
  unit ->
  (cache_entry, string) result
val get : Workspace_utils.config -> key:string -> (cache_entry option, string) result
val delete : Workspace_utils.config -> key:string -> (bool, string) result
val list : Workspace_utils.config -> ?tag:string -> unit -> cache_entry list
val clear : Workspace_utils.config -> (int, string) result
val stats : Workspace_utils.config -> (int * int * float, string) result
val format_stats : int * int * float -> string

(** {1 Eviction} *)

val evict_expired : Workspace_utils.config -> int
val maybe_evict_expired : Workspace_utils.config -> int
val count_entries : Workspace_utils.config -> int
val last_batch_eviction : float Atomic.t
val reset_cached_entry_count : unit -> unit
