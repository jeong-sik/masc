(** Section builders for mission briefing (communication / alignment /
    watch).

    The full surface (section labels, signal classifiers, predicate
    helpers, per-section builders) is internal — only the top-level
    composer {!build_briefing_sections} is consumed externally by
    [dashboard_mission_briefing.ml]. *)

val build_briefing_sections :
  mission_summary_json:Yojson.Safe.t ->
  sessions:Yojson.Safe.t list ->
  agents:Yojson.Safe.t list ->
  recent_messages:Yojson.Safe.t list ->
  metadata_gaps:Yojson.Safe.t list ->
  string * Yojson.Safe.t list
(** Build the three briefing sections (communication, alignment, watch)
    from operator facts plus the metadata gaps from
    {!Briefing_gaps.collect_metadata_gaps}.

    Returns [(watch_summary, sections_json)] where [watch_summary] is
    the Watch section's prose summary (used as the briefing's lead
    line) and [sections_json] is a list of three annotated section
    objects with [id / label / status / summary / evidence /
    signal_class / evidence_quality / provenance / authoritative]
    fields. *)
