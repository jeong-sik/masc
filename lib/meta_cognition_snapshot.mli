(** Meta_cognition_snapshot — Data loading + JSON snapshot
    builders for the meta-cognition read model.

    One of 6 sub-modules included into the {!Meta_cognition}
    facade.  Sister modules ({!Meta_cognition_types},
    {!Meta_cognition_rules}, {!Meta_cognition_parse},
    {!Meta_cognition_interpret}, {!Meta_cognition_digest}) are
    already pinned via their own .mli files; this module
    completes the .mli surface for the cluster.

    Only the 2 JSON-builder entries leak through the
    [include Meta_cognition_snapshot] cascade in
    [meta_cognition.ml] to satisfy {!Meta_cognition.snapshot_json}
    / {!Meta_cognition.summary_json}.  Everything else is
    internal data-loading + signal-extraction machinery.

    Internal: 17 helpers + [StringMap] alias stay private —
    \[load_jsonl_safe] (line-oriented JSONL reader),
    \[load_board_posts] / \[load_board_comments] /
    \[load_board_vote_count] / \[load_governance_cases]
    (board / governance fixture loaders),
    \[post_sources] / \[comment_sources]
    (?hearth_filter projectors), \[belief_json] /
    \[tension_json] / \[desire_json] / \[social_edges_json]
    (per-rule JSON builders consuming
    {!Meta_cognition_rules.belief_rule} /
    [tension_rule] / [desire_rule]),
    \[active_task_count] / \[stagnation_score],
    \[assoc_subset] / \[assoc_subset_or_null] /
    \[first_item_or_null] (JSON projection helpers used by
    {!summary_json}).  All consumed only inside
    {!snapshot_json} / {!summary_json}'s pipelines. *)

val snapshot_json :
  ?hearth:string ->
  limit:int ->
  Coord.config ->
  Yojson.Safe.t
(** [snapshot_json ?hearth ~limit config] returns the full
    meta-cognition JSON snapshot for [config].  Aggregates:

    - Belief signals (top-K matches per rule from
      {!Meta_cognition_rules}).
    - Tension signals (governance-case-correlated).
    - Desire signals.
    - Social edges (post → reply discourse graph).
    - Stagnation indicators (active task / agent counts).

    [?hearth] filters posts + comments by hearth label (when
    set).  [~limit] caps the per-signal result list length to
    keep the snapshot bounded for dashboard polling. *)

val summary_json : ?hearth:string -> Coord.config -> Yojson.Safe.t
(** [summary_json ?hearth config] returns a compact summary
    projection of {!snapshot_json} suitable for the
    [Meta_cognition.summary_input] decoder.  Fewer fields per
    signal — only the dominant belief / top tension / top
    desire are extracted via {!first_item_or_null}.  Used by
    higher-level interpretation passes
    ({!Meta_cognition_interpret.interpret}). *)
