(** Keeper_memory_os_io — append-only atomic I/O for tiered memory files.

    Path helpers, atomic writes, and bounded tail reads for facts,
    events/episodes, and external tool-result archives. *)

open Keeper_memory_os_types

(** {1 Path helpers} *)

val facts_path : keeper_id:string -> string

(** RFC-0244 Tier 2: keeper ids that currently have a [*.facts.jsonl] store, for
    the cross-keeper consolidation sweep. Excludes the reserved shared id; sorted. *)
val list_fact_store_keeper_ids : unit -> string list

val events_path : keeper_id:string -> string
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

(** Like {!next_generation}, but preserves a caller-provided generation lower
    bound while still advancing the counter past it. *)
val next_generation_with_floor : floor:int -> keeper_id:string -> trace_id:string -> int

(** {1 Atomic writes} *)

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
val save_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t -> unit
val load_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t option

(** {1 Bounded tail reads} *)

val read_facts_all : keeper_id:string -> fact list
(** Read every fact in the store, failing if any JSONL row is malformed or does
    not match the fact schema. Use this before destructive rewrites so corrupt
    input cannot be partially dropped and overwritten. *)
val read_facts_all_strict : keeper_id:string -> (fact list, string) result
val read_facts_tail : keeper_id:string -> n:int -> fact list
val read_events_tail : keeper_id:string -> n:int -> episode list
val read_episodes_tail : keeper_id:string -> n:int -> episode list

(** {1 Retention (RFC-0239 Q4, supersedes RFC-0238 Capped_by_score)} *)

(** Per-keeper fact retention target: the size the cap trims the store back to.
    NOT the recall scan window — the store holds up to {!fact_store_max} between
    caps, so recall scans {!fact_store_max} (not this) to see the whole bounded
    store. *)
val fact_recall_window : int

(** Upper bound on a bounded store between caps: the retention cap [trigger]
    (= [fact_recall_window] + [fact_recall_window]/2). SSOT shared by the
    librarian write path (cap trigger) and recall (tail scan window) so the read
    side scans the entire bounded store — including the high-rank rows a fresh cap
    writes at the file head, which a [fact_recall_window]-sized scan would miss. *)
val fact_store_max : int

(** Read and parse every fact in the store (unbounded; used by retention). *)
val read_all_facts : keeper_id:string -> fact list

(** When the fact store exceeds [trigger], keep the [keep] highest-[rank]ed
    facts and atomically rewrite the file; otherwise no-op. Returns the number
    of facts dropped. The hysteresis ([trigger] > [keep]) keeps rewrites off the
    per-turn hot path. *)
val cap_facts :
  keeper_id:string -> keep:int -> trigger:int -> rank:(fact -> float) -> int

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
    [cap_facts] pair, giving the store write-time dedup. *)
val merge_and_cap_facts :
  keeper_id:string
  -> merge:(existing:fact -> incoming:fact -> fact)
  -> incoming:fact list
  -> keep:int
  -> trigger:int
  -> rank:(fact -> float)
  -> fact_merge_stats

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
