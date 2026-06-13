(** Durable keeper working-state vessel.

    This module owns the pure data shape for unresolved keeper obligations:
    active PRs, claimed tasks, investigations, or verification loops that must
    survive compaction, handoff, and resume.

    Spec mirror: [specs/keeper-state-machine/KeeperWorkingStateLifecycle.tla].
    This PR intentionally stays pure; persistence, checkpoint injection, and
    dashboard projection are follow-up wiring layers. *)

type loop_status =
  | Active
  | Resolved
  | Archived

val loop_status_to_string : loop_status -> string
val loop_status_of_string : string -> loop_status option
val loop_status_to_json : loop_status -> Yojson.Safe.t

type evidence_ref = {
  kind : string;
  target : string;
}

type six_w = {
  who : string;
  what : string;
  when_ : string;
  where_ : string;
  why : string;
  how : string;
}

type loop = {
  id : string;
  title : string;
  status : loop_status;
  six_w : six_w;
  evidence_refs : evidence_ref list;
  resolution_refs : evidence_ref list;
  updated_at_unix : float;
}

type t = {
  active_loops : loop list;
  resolved_loops : loop list;
  archived_loops : loop list;
  prompt_digest_ids : string list;
}

val empty : t
val make_evidence_ref : kind:string -> target:string -> evidence_ref

val make_six_w :
  who:string ->
  what:string ->
  when_:string ->
  where_:string ->
  why:string ->
  how:string ->
  six_w

val make_loop :
  id:string ->
  title:string ->
  ?status:loop_status ->
  six_w:six_w ->
  evidence_refs:evidence_ref list ->
  ?resolution_refs:evidence_ref list ->
  updated_at_unix:float ->
  unit ->
  loop

val active_open_loop_count : t -> int

(** Rebuild [prompt_digest_ids] deterministically.  Active loop IDs are always
    preserved before resolved-loop IDs; [max_digest] only caps the resolved
    tail, never active responsibility. *)
val compact : ?max_digest:int -> t -> t

(** Implement the TLA [ResumeFromDigest] action: merge a persisted ledger
    ([persisted]) into the ledger freshly projected from the current [STATE]
    snapshot ([current]) on resume/compaction.

    A persisted active loop survives even when [current] omits it, so an open
    loop is not silently lost when an importance heuristic drops the reminder
    and the model fails to re-emit it. A loop the [current] snapshot has since
    resolved/archived does not resurrect, and resolved/archived history is
    carried forward without duplicating ids.

    Callers gate this to resume/compaction turns only; on a normal turn the
    current snapshot is authoritative so a dropped loop still clears. *)
val merge_resume : persisted:t -> current:t -> t

val capture_loop : ?max_digest:int -> t -> loop -> (t, string) result

val resolve_loop :
  ?max_digest:int ->
  t ->
  loop_id:string ->
  resolution_refs:evidence_ref list ->
  updated_at_unix:float ->
  (t, string) result

val archive_resolved_loop :
  ?max_digest:int ->
  ?max_archived:int ->
  t ->
  loop_id:string ->
  (t, string) result

(** Validate the TLA-mirrored safety invariants:
    - loop IDs are unique and disjoint across lifecycle buckets
    - every known loop carries 6W metadata and evidence refs
    - resolved/archived loops carry resolution refs
    - active loops are present in [prompt_digest_ids] *)
val validate : t -> (unit, string list) result

val loop_to_json : loop -> Yojson.Safe.t
val loop_of_json : Yojson.Safe.t -> (loop, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
