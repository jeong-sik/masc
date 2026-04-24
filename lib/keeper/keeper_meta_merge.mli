(** Field-ownership merges for keeper_meta on CAS retry (#9769).

    The existing [write_meta_with_retry] re-reads the disk version on
    conflict and then writes the caller's payload wholesale, only
    bumping [meta_version] to [latest.meta_version]. When the retry
    loser is the turn-failure writer and the winner is the heartbeat
    fiber, the heartbeat's updates to [joined_room_ids] and
    [last_seen_seq_by_room] are clobbered — even though the turn path
    never touches those fields. This is false sharing on a single
    version counter.

    A correct three-way merge requires the caller to declare which
    fields it owns. This module provides named merge strategies; the
    identity function ([caller_wins]) preserves the historical
    behaviour for the call sites that still need it.

    Analogy: this is the Git three-way merge pattern expressed with
    explicit field ownership per writer, or a minimal CRDT with
    per-field LWW where the "W" is the declared owner. *)

type t = latest:Keeper_types.keeper_meta -> caller:Keeper_types.keeper_meta -> Keeper_types.keeper_meta

val caller_wins : t
(** Take every field from the caller except [meta_version], which
    follows the disk version. This is the historical behaviour of
    [write_meta_with_retry]. *)

val heartbeat_fields_from_disk : t
(** Take heartbeat-owned fields ([joined_room_ids],
    [last_seen_seq_by_room]) from [latest]; everything else from
    [caller]. Use this from turn-completion and turn-failure paths
    where the caller never touches heartbeat fields but concurrent
    heartbeat writes keep winning the CAS race. *)
