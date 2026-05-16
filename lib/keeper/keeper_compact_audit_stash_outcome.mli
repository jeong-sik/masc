(** Keeper_compact_audit_stash_outcome — closed sum naming the two
    paths through [Keeper_compact_audit.Pending.stash].

    The Pending table is keyed by [keeper_name] (not compaction_id)
    because OAS Compaction_started events do not carry a
    compaction-scoped correlation id.  When a second [Start] event for
    the same keeper arrives before the first one's matching [Complete],
    [Hashtbl.replace] silently overwrites the previous (compaction_id,
    ts_unix) tuple.  The lost pair surfaces later only as an
    [Orphan_complete] — operators never learn that two concurrent
    compactions raced.

    This outcome makes the replacement observable so a rising
    [replaced_dropped] rate is the operational signal that
    Compaction_started is firing twice for the same keeper without an
    intervening Compaction_completed. *)

type t =
  | Inserted
      (** No prior stash for this keeper.  Normal path. *)
  | Replaced_dropped of {
      previous_compaction_id : string;
      previous_ts_unix : float;
    }
      (** A prior (compaction_id, ts_unix) was overwritten without ever
          being [take]n.  The previous compaction's [Start] payload is
          lost; its [Complete] (if it arrives) will appear as an
          [Orphan_complete] in [pair_events]. *)

val to_label : t -> string
