(** Keeper_memory_os_io — append-only atomic I/O for tiered memory files.

    Path helpers, atomic writes, and bounded tail reads for facts,
    events/episodes, and external tool-result archives. *)

open Keeper_memory_os_types

(** {1 Path helpers} *)

val facts_path : keeper_id:string -> string
val facts_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** RFC-0244 Tier 2: keeper ids that currently have a [*.facts.jsonl] store, for
    the cross-keeper consolidation sweep. Excludes the reserved shared id; sorted. *)
val list_fact_store_keeper_ids : unit -> string list
val list_fact_store_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

(** Base-path-scoped variant of {!list_fact_store_keeper_ids}; avoids ambient
    config-dir reads in multi-workspace dashboard routes. *)
val list_fact_store_keeper_ids_for_base_path : base_path:string -> string list

val events_path : keeper_id:string -> string
val events_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

type legacy_memory_file =
  | Legacy_facts
  | Legacy_events

val supported_legacy_memory_files : legacy_memory_file list
val legacy_memory_filename : legacy_memory_file -> string
val current_path_for_legacy_memory_filename :
  keepers_dir:string -> keeper_id:string -> filename:string -> string option
(** Map a legacy per-keeper Memory OS filename under [.masc/keepers/<keeper>/]
    to the current store path under [keepers_dir], when the filename is a
    supported legacy memory artifact. *)
val episodes_dir : keeper_id:string -> string
val tool_results_dir : keeper_id:string -> string
val tool_result_path : keeper_id:string -> tool_call_id:string -> string
val episode_path : keeper_id:string -> trace_id:string -> generation:int -> string

(** Reserve the next episode generation for [(keeper_id, trace_id)].
    The reservation is serialized with a per-trace file lock and a small counter
    file, so concurrent callers cannot receive the same generation. Gaps are
    possible if a caller reserves a generation and later fails before appending
    the episode. *)
val next_generation : keeper_id:string -> trace_id:string -> int

(** BasePath-scoped variant of {!next_generation}. Use this whenever the
    caller already owns a workspace config; it does not derive the runtime root
    from cached ambient BasePath/cwd state. *)
val next_generation_for_base_path :
  base_path:string -> keeper_id:string -> trace_id:string -> int

(** Like {!next_generation}, but preserves a caller-provided generation lower
    bound while still advancing the counter past it. *)
val next_generation_with_floor : floor:int -> keeper_id:string -> trace_id:string -> int

(** BasePath-scoped variant of {!next_generation_with_floor}. *)
val next_generation_with_floor_for_base_path :
  base_path:string -> floor:int -> keeper_id:string -> trace_id:string -> int

(** {1 Atomic writes} *)

(** Run [f] against the channel then close it, releasing the descriptor on every
    exit path — including when [close_out]'s flush raises, which OCaml's
    [close_out] leaves the fd open on. The body's exception propagates (so
    callers can skip a rename / report the write failure). Exposed for testing
    the fd-release guarantee. *)
val with_out_channel : out_channel -> f:(out_channel -> unit) -> unit

val append_fact : keeper_id:string -> fact -> unit
val append_event : keeper_id:string -> episode -> unit
val append_episode : keeper_id:string -> episode -> unit

(** Serialize a cross-file episode bundle write for one keeper. Callers that
    write facts plus episode/event artifacts should take this before the facts
    lock, then publish [events_path] last as the reader-visible commit marker. *)
val with_episode_bundle_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t -> keeper_id:string -> (unit -> 'a) -> 'a

val append_episode_bundle : keeper_id:string -> episode -> unit
val rewrite_facts_atomically : keeper_id:string -> fact list -> unit
val rewrite_facts_atomically_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> fact list -> unit
val rewrite_facts_atomically_for_base_path :
  base_path:string -> keeper_id:string -> fact list -> unit

(** {1 Facts snapshot CAS} *)

(** Canonical-JSON fingerprint of a fact (stable key order — see
    {!Keeper_memory_os_types}). *)
val fact_fingerprint : fact -> string

(** [same_fact_snapshot snapshot current] is true iff the two fact lists are
    positionally byte-identical. Used for read-outside-lock / rewrite-under-lock
    optimistic concurrency: a snapshot classified without the lock is revalidated
    under the lock and a stale rewrite abandoned if any concurrent writer changed
    the store. Line count / file size are NOT sound CAS keys. *)
val same_fact_snapshot : fact list -> fact list -> bool

(** [with_facts_lock ?clock ~keeper_id ~on_timeout f] runs [f] holding the
    per-keeper facts lock. On flock-acquisition timeout, [on_timeout msg] produces
    the result instead of raising {!File_lock_eio.Flock_timeout}, so callers can
    return a typed skip/no-op for a contended cycle. Non-timeout exceptions from
    [f] propagate after the lock finalizer runs. Keep [on_timeout] total and
    non-raising so timeout remains a typed result, not a second failure path. *)
val with_facts_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keeper_id:string
  -> on_timeout:(string -> 'a)
  -> (unit -> 'a)
  -> 'a
val save_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t -> unit
val load_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t option

(** {1 Bounded tail reads} *)

val read_facts_all : keeper_id:string -> fact list
val read_facts_all_for_keepers_dir : keepers_dir:string -> keeper_id:string -> fact list
(** Read every fact in the store, failing if any JSONL row is malformed or does
    not match the fact schema. Use this before destructive rewrites so corrupt
    input cannot be partially dropped and overwritten. *)
val read_facts_all_strict : keeper_id:string -> (fact list, string) result
val read_facts_all_strict_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (fact list, string) result
val read_facts_tail : keeper_id:string -> n:int -> fact list
val read_facts_tail_for_base_path : base_path:string -> keeper_id:string -> n:int -> fact list
val read_events_tail : keeper_id:string -> n:int -> episode list
val read_episodes_tail : keeper_id:string -> n:int -> episode list
val read_episodes_all : keeper_id:string -> episode list
(** Read every persisted episode in source order. Any malformed row/file raises;
    no child episode is silently dropped. *)

(** Read and parse every fact in the store. *)
val read_all_facts : keeper_id:string -> fact list

(** Outcome of a [merge_facts] write: how many incoming claims were folded into
    an existing fact and persisted as new facts. *)
type fact_merge_stats =
  { merged : int
  ; appended : int
  }

(** Librarian write path. Upsert [incoming] facts by explicit identity and retain
    every resulting row. *)
val merge_facts :
  keeper_id:string
  -> merge:(existing:fact -> incoming:fact -> fact)
  -> incoming:fact list
  -> fact_merge_stats

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
