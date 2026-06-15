(** Keeper_memory_os_io — append-only atomic I/O for tiered memory files.

    Path helpers, atomic writes, and bounded tail reads for facts,
    events/episodes, and external tool-result archives. *)

open Keeper_memory_os_types

(** {1 Path helpers} *)

val facts_path : keeper_id:string -> string
val events_path : keeper_id:string -> string
val episodes_dir : keeper_id:string -> string
val tool_results_dir : keeper_id:string -> string
val tool_result_path : keeper_id:string -> tool_call_id:string -> string
val episode_path : keeper_id:string -> trace_id:string -> generation:int -> string

(** {1 Atomic writes} *)

val append_fact : keeper_id:string -> fact -> unit
val append_event : keeper_id:string -> episode -> unit
val append_episode : keeper_id:string -> episode -> unit
val append_episode_bundle : keeper_id:string -> episode -> unit
val save_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t -> unit
val load_tool_result : keeper_id:string -> tool_call_id:string -> Yojson.Safe.t option

(** {1 Bounded tail reads} *)

val read_facts_tail : keeper_id:string -> n:int -> fact list
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

module For_testing : sig
  val with_keepers_dir : string -> (unit -> 'a) -> 'a
end
