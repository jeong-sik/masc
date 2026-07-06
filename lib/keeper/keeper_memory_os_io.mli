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
val list_fact_store_keeper_ids_result : unit -> (string list, string) result
val list_fact_store_keeper_ids_for_keepers_dir : keepers_dir:string -> string list
val list_fact_store_keeper_ids_for_keepers_dir_result :
  keepers_dir:string -> (string list, string) result

(** Base-path-scoped variant of {!list_fact_store_keeper_ids}; avoids ambient
    config-dir reads in multi-workspace dashboard routes. *)
val list_fact_store_keeper_ids_for_base_path : base_path:string -> string list
val list_fact_store_keeper_ids_for_base_path_result :
  base_path:string -> (string list, string) result

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
    the episode. A persisted counter must be a non-negative integer; malformed or
    negative counters are read failures, not missing counters. *)
val next_generation : keeper_id:string -> trace_id:string -> int
val next_generation_result : keeper_id:string -> trace_id:string -> (int, string) result

(** Like {!next_generation}, but preserves a caller-provided generation lower
    bound while still advancing the counter past it. *)
val next_generation_with_floor : floor:int -> keeper_id:string -> trace_id:string -> int
val next_generation_with_floor_result :
  floor:int -> keeper_id:string -> trace_id:string -> (int, string) result

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

(** Fact JSONL read diagnostics. Legacy fact readers still return only facts,
    while [*_with_errors] variants preserve malformed row diagnostics. *)
type fact_jsonl_read_scope =
  | Fact_read_full_file
  | Fact_read_tail_window

type fact_jsonl_parse_error =
  { path : string
  ; scope : fact_jsonl_read_scope
  ; line_index : int
  ; message : string
  }

type fact_read_with_errors =
  { facts : fact list
  ; parse_errors : fact_jsonl_parse_error list
  }

val fact_jsonl_parse_error_to_string : fact_jsonl_parse_error -> string

(** {1 Bounded tail reads} *)

val read_facts_all : keeper_id:string -> fact list
val read_facts_all_for_keepers_dir : keepers_dir:string -> keeper_id:string -> fact list

val read_facts_all_with_errors : keeper_id:string -> fact_read_with_errors

val read_facts_all_with_errors_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> fact_read_with_errors

(** Read every fact in the store, failing if any JSONL row is malformed or does
    not match the fact schema. Use this before destructive rewrites so corrupt
    input cannot be partially dropped and overwritten. *)
val read_facts_all_strict : keeper_id:string -> (fact list, string) result
val read_facts_all_strict_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (fact list, string) result
val read_facts_tail : keeper_id:string -> n:int -> fact list

val read_facts_tail_with_errors :
  keeper_id:string -> n:int -> fact_read_with_errors

val read_facts_tail_with_errors_for_base_path :
  base_path:string -> keeper_id:string -> n:int -> fact_read_with_errors

val read_facts_tail_with_errors_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> n:int -> fact_read_with_errors

val read_facts_tail_for_base_path : base_path:string -> keeper_id:string -> n:int -> fact list

(** Episode/event read diagnostics. Legacy episode readers still return only
    parseable episodes, while [*_with_errors] variants preserve malformed
    event-row / episode-file diagnostics. *)
type episode_read_scope =
  | Episode_read_events_tail
  | Episode_read_episode_dir
  | Episode_read_episode_file
  | Episode_read_episode_file_unlink

type episode_parse_error =
  { episode_parse_path : string
  ; episode_parse_scope : episode_read_scope
  ; episode_parse_line_index : int
  ; episode_parse_message : string
  }

type episode_read_with_errors =
  { episodes : episode list
  ; episode_parse_errors : episode_parse_error list
  }

val episode_parse_error_to_string : episode_parse_error -> string

val read_events_tail : keeper_id:string -> n:int -> episode list
val read_events_tail_with_errors :
  keeper_id:string -> n:int -> episode_read_with_errors
val read_episodes_tail : keeper_id:string -> n:int -> episode list
val read_episodes_tail_with_errors :
  keeper_id:string -> n:int -> episode_read_with_errors

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

(** RFC-0272 (defect D): bound the [episodes/] directory by file count. When the
    parseable-file count exceeds [trigger], keep the [keep] most-recent files by
    recency and unlink the rest; otherwise no-op. Unparseable files are left
    untouched. Returns the number actually unlinked; use
    {!cap_episode_files_with_errors} when unlink/read diagnostics are needed. *)
val cap_episode_files : keeper_id:string -> keep:int -> trigger:int -> int

type episode_file_cap_result =
  { episode_files_dropped : int
  ; episode_file_cap_errors : episode_parse_error list
  }

val cap_episode_files_with_errors :
  keeper_id:string -> keep:int -> trigger:int -> episode_file_cap_result

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

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
