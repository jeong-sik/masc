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

type migration_stats =
  { moved_files : int
  ; deduplicated_files : int
  }

type migration_error =
  { source : string
  ; destination : string
  ; detail : string
  }

type migration_report =
  { stats : migration_stats
  ; errors : migration_error list
  }

val migration_error_to_string : migration_error -> string

val migrate_legacy_config_store :
  base_path:string -> migration_report
(** Move Memory OS runtime artifacts from the canonical historical
    [<base>/.masc/config/keepers] root into the BasePath runtime root. Config
    files remain in place. Existing byte-identical destinations are
    deduplicated; divergent destinations are preserved and reported without
    stopping migration of unrelated keepers or artifacts. *)

val episodes_dir : keeper_id:string -> string
val episodes_dir_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string
val tool_results_dir : keeper_id:string -> string
val tool_result_path : keeper_id:string -> tool_call_id:string -> string
val episode_path : keeper_id:string -> trace_id:string -> generation:int -> string

(** Reserve the next episode generation for [(keeper_id, trace_id)].
    The reservation is serialized with a per-trace file lock and a small counter
    file, so concurrent callers cannot receive the same generation. Gaps are
    possible if a caller reserves a generation and later fails before appending
    the episode. *)
val next_generation : keeper_id:string -> trace_id:string -> int

(** Like {!next_generation}, but preserves a caller-provided generation lower
    bound while still advancing the counter past it. *)
val next_generation_with_floor :
  floor:int -> keeper_id:string -> trace_id:string -> int

val next_generation_with_floor_for_keepers_dir :
  keepers_dir:string -> floor:int -> keeper_id:string -> trace_id:string -> int

(** {1 Atomic writes} *)

(** Run [f] against the channel then close it, releasing the descriptor on every
    exit path — including when [close_out]'s flush raises, which OCaml's
    [close_out] leaves the fd open on. The body's exception propagates (so
    callers can skip a rename / report the write failure). Exposed for testing
    the fd-release guarantee. *)
val with_out_channel : out_channel -> f:(out_channel -> unit) -> unit

val append_fact : keeper_id:string -> fact -> unit
val append_event : keeper_id:string -> episode -> unit
val append_event_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> episode -> unit
val append_episode : keeper_id:string -> episode -> unit
val append_episode_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> episode -> unit

type operation_episode =
  { episode : episode
  ; model_id : string
  ; provider_latency_ms : float
  }

val save_operation_episode :
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  model_id:string ->
  provider_latency_ms:float ->
  episode ->
  (unit, string) result
(** Atomically stage one provider-produced episode under a deterministic
    operation id before publishing facts/events. *)

val load_operation_episode :
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  (operation_episode option, string) result

val stage_operation_episode_once :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  model_id:string ->
  provider_latency_ms:float ->
  episode ->
  (operation_episode, string) result
(** Atomically install the first stage for an operation and return the winning
    stage. Concurrent producers never overwrite one another. *)

val operation_event_committed :
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  (bool, string) result
(** Check the events commit log for [operation_id]. Malformed event rows are an
    explicit recovery event: raw rows are durably quarantined before the valid
    prefix/set is atomically rewritten. A quarantine or rewrite failure is
    returned and is never treated as "not committed". Call while holding
    {!with_episode_bundle_lock_for_keepers_dir}. *)

type operation_episode_state =
  | Operation_absent
  | Operation_staged of operation_episode
  | Operation_committed of operation_episode

val inspect_operation_episode :
  clock:float Eio.Time.clock_ty Eio.Resource.t option ->
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  (operation_episode_state, string) result
(** Inspect an operation and atomically distinguish absence, a provider result
    staged before publication, and a fully committed event. Missing staged
    operations avoid an event-log scan. *)

val append_operation_event :
  keepers_dir:string ->
  keeper_id:string ->
  operation_id:string ->
  model_id:string ->
  provider_latency_ms:float ->
  episode ->
  (unit, string) result
(** Append an episode event carrying [operation_id]. Call only after
    {!operation_event_committed} returned [false], under the bundle lock. *)

(** Serialize a cross-file episode bundle write for one keeper. Callers that
    write facts plus episode/event artifacts should take this before the facts
    lock, then publish [events_path] last as the reader-visible commit marker. *)
val with_episode_bundle_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  keeper_id:string ->
  (unit -> 'a) ->
  'a

val with_episode_bundle_lock_for_keepers_dir :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  keepers_dir:string ->
  keeper_id:string ->
  (unit -> 'a) ->
  'a

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

(** {1 Retention (RFC-0239 Q4, supersedes RFC-0238 Capped_by_score)} *)

(** Alias for {!Keeper_memory_os_policy.fact_recall_window}; retained on the IO
    surface for compatibility with existing callers. *)
val fact_recall_window : int

(** Alias for {!Keeper_memory_os_policy.fact_store_max}; retained on the IO
    surface for compatibility with existing callers. *)
val fact_store_max : int

(** RFC-0272 (defect D): aliases for the episode-log retention bounds in
    {!Keeper_memory_os_policy}. The low-water values exceed
    {!Keeper_memory_os_policy.recall_episode_tail_scan}, so a trim cannot starve
    recall. *)
val event_recall_window : int

val event_store_max : int
val episode_file_window : int
val episode_file_store_max : int

(** Pure hysteresis decision for the episode-log caps: [None] below [trigger]
    (no-op), [Some keep] above. Exposed for the watermark unit tests. *)
val trim_target : count:int -> keep:int -> trigger:int -> int option

(** RFC-0272 (defect D): bound [events.jsonl] by line count. When the line count
    exceeds [trigger], keep the last [keep] raw lines (newest, byte-faithful,
    malformed-line tolerant) and atomically rewrite; otherwise no-op. Returns the
    number of lines dropped. *)
val cap_events : keeper_id:string -> keep:int -> trigger:int -> int
val cap_events_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> keep:int -> trigger:int -> int

(** RFC-0272 (defect D): bound the [episodes/] directory by file count. When the
    parseable-file count exceeds [trigger], keep the [keep] most-recent files by
    recency and best-effort unlink the rest; otherwise no-op. Unparseable files
    are left untouched. Returns the number unlinked. *)
val cap_episode_files :
  keeper_id:string -> keep:int -> trigger:int -> int
val cap_episode_files_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> keep:int -> trigger:int -> int

(** Read and parse every fact in the store (unbounded; used by retention). *)
val read_all_facts : keeper_id:string -> fact list

(** When the fact store exceeds [trigger], keep the [keep] highest-[rank]ed
    facts and atomically rewrite the file; otherwise no-op. Returns the number
    of facts dropped. The hysteresis ([trigger] > [keep]) keeps rewrites off the
    per-turn hot path. RFC-0259 §3.6 (P5): rows expired at [now] (typed
    [valid_until] boundary) are dropped before the trigger gate and ranking, so
    an under-cap store does not retain them; expired rows count toward the
    returned total. *)
val cap_facts :
  now:float
  -> keeper_id:string
  -> keep:int
  -> trigger:int
  -> rank:(fact -> float)
  -> int

(** Outcome of a [merge_and_cap_facts] write: how many incoming claims were
    folded into an existing fact ([merged]), persisted as new facts
    ([appended]), and removed by the retention cap ([dropped]). *)
type fact_merge_stats =
  { merged : int
  ; appended : int
  ; dropped : int
  }

(** RFC-0243: the librarian write path. Upsert [incoming] facts into the store by
    normalized claim identity — a re-observation of an existing claim is folded
    in via [merge] (so confidence/access/verification evolve) instead of
    appending an immortal duplicate — then apply the [keep]/[trigger]/[rank]
    retention cap, all in a single atomic rewrite. Replaces the blind append +
    [cap_facts] pair, giving the store write-time dedup. RFC-0259 §3.6 (P5): rows
    expired at [now] are dropped on the same [valid_until] boundary the GC sweep
    uses, before the trigger gate, so the librarian write path keeps the on-disk
    store free of expired rows even below the cap; they count toward [dropped]. *)
val merge_and_cap_facts :
  now:float
  -> keeper_id:string
  -> merge:(existing:fact -> incoming:fact -> fact)
  -> incoming:fact list
  -> keep:int
  -> trigger:int
  -> rank:(fact -> float)
  -> fact_merge_stats

val merge_and_cap_facts_for_keepers_dir :
  keepers_dir:string
  -> now:float
  -> keeper_id:string
  -> merge:(existing:fact -> incoming:fact -> fact)
  -> incoming:fact list
  -> keep:int
  -> trigger:int
  -> rank:(fact -> float)
  -> fact_merge_stats

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
