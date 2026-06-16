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

(** RFC-0247 §2.7: per-keeper association events, alongside the fact store. *)
val edges_path : keeper_id:string -> string

(** {1 Atomic writes} *)

val append_fact : keeper_id:string -> fact -> unit
val append_edge : keeper_id:string -> Keeper_memory_os_edges.edge -> unit

(** Append every co-occurrence edge of an episode (RFC-0247 §2.7). Append-only
    and unbounded in slice 1 — see [edges_path]'s growth note in the .ml. *)
val append_edges : keeper_id:string -> Keeper_memory_os_edges.edge list -> unit
val append_event : keeper_id:string -> episode -> unit
val append_episode : keeper_id:string -> episode -> unit
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

(** Read every association event in the keeper's edge store (RFC-0247 §2.7). *)
val read_edges_all : keeper_id:string -> Keeper_memory_os_edges.edge list

(** The aggregated read view: per-(src,dst,relation) associations with Hebbian
    weight, the surface a spreading-activation recall consumes. *)
val read_associations : keeper_id:string -> Keeper_memory_os_edges.association list
val read_events_tail : keeper_id:string -> n:int -> episode list
val read_episodes_tail : keeper_id:string -> n:int -> episode list

(** {1 Retention (RFC-0239 Q4, supersedes RFC-0238 Capped_by_score)} *)

(** Per-keeper fact recall window / retention target. The store is bounded to
    this many facts; recall reads up to this many candidates (not just the last
    few), so score ranking selects the globally best facts in the bounded
    store. *)
val fact_recall_window : int

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
