(** Summaries of checkpoint files: what a list or a heartbeat needs, read from
    the head and the few objects it names instead of the whole history.

    [summarize_canonical] and [summarize_agent_core_history_file] describe a
    session's canonical file or one history snapshot. The summary of a
    canonical file is cached per path under [canonical_identity] (device,
    inode, size and mtime), which changes whenever a writer publishes a new
    file. [cached_summary] answers only while the file at the path still has
    the identity the summary was taken under. [publish_summary_after_parse]
    publishes only when the identity did not change during the read, and
    [publish_summary_after_write] publishes the file a save just installed.
    [summary_key] names the cache entry of a path through the session roots
    that [resolve_session_root] resolves once per spelling and
    [remember_session_root] records. [Keeper_checkpoint_store] includes this
    module. *)

open Keeper_checkpoint_store_decode

type 'a checkpoint_summary =
  { created_at : float
  ; message_count : int
  ; system_prompt : string option
  ; latest : 'a option
  }

val protect_summary_read :
  on_exception:(exn -> 'a) -> (unit -> ('b, 'a) result) -> ('b, 'a) result

val canonical_read_exception :
  exn -> checkpoint_load_error

val summarize_canonical :
  session_dir:string ->
  session_id:string ->
  latest:(Agent_core_base.Types.message -> 'a option) ->
  ('a checkpoint_summary,
   checkpoint_load_error)
  result

val summarize_agent_core_history_file :
  session_dir:string ->
  snapshot_id:string ->
  latest:(Agent_core_base.Types.message -> 'a option) ->
  ('a checkpoint_summary,
   checkpoint_load_error)
  result

(** The identity of a canonical file. Every writer publishes the file by
    atomic rename, so a changed file is a new inode; equal fields mean the
    file is still the one a summary describes. *)
type canonical_identity =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

(** Whether this process has seen every object a head names: it wrote them,
    or a load read them back against their digests. *)
type head_objects =
  | Objects_seen
  | Objects_unchecked

(** The scalars other paths need from a canonical file, with the head they
    came from and the identity of the file. *)
type canonical_summary =
  { identity : canonical_identity
  ; summary_session_id : string
  ; summary_turn_count : int
  ; summary_message_count : int
  ; summary_head : Agent_core.Checkpoint_objects.head
  ; summary_objects : head_objects
  }

val canonical_identity_equal :
  canonical_identity -> canonical_identity -> bool

val canonical_identity_of_stats : Unix.stats -> canonical_identity

val canonical_identity_opt : string -> canonical_identity option

val remember_session_root : spelling:string -> string -> unit

val resolve_session_root : string -> (string, Unix.error) result

val summary_key : string -> string option

val cached_summary : canonical_path:string -> canonical_summary option

val summary_of_head :
  identity:canonical_identity ->
  objects:head_objects -> Agent_core.Checkpoint_objects.head -> canonical_summary

val publish_summary : canonical_path:string -> canonical_summary -> unit

val publish_summary_after_parse :
  canonical_path:string ->
  identity_before:canonical_identity option ->
  objects:head_objects -> Agent_core.Checkpoint_objects.head -> unit

val publish_summary_after_write :
  canonical_path:string -> Agent_core.Checkpoint_objects.head -> canonical_identity option
