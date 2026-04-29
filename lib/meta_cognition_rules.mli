(** Meta_cognition_rules — signal detection rules + interaction
    classification for board posts and comments.

    Defines the canonical {!Meta_cognition_types.belief_rule} /
    [tension_rule] / [desire_rule] tables consumed by
    {!Meta_cognition_snapshot} to classify board content into
    meta-cognitive signals.

    {!Meta_cognition} re-exports nothing from this module — the
    rules are an internal SSOT for the snapshot pipeline.  Only
    the rule lists + the two predicates referenced by
    [Meta_cognition_snapshot] are exposed; signal-keyword lists
    and intermediate predicate helpers stay private to prevent
    drift between the rule definitions and ad-hoc reuse.

    @since God file decomposition — extracted from
    meta_cognition.ml *)

(** {1 Rule tables}

    These three lists are the SSOT for board-content
    classification.  Adding a new rule requires extending the
    correct list (+ updating the operator runbook for the new
    rule id). *)

val belief_rules : Meta_cognition_types.belief_rule list
(** Three rules pinned at the contract seam:
    - [belief:masc_tools_blocked] — keeper-class agents
      believe [masc_*] introspection/admin tools are
      blocked
    - [belief:idle_backlog_empty] — room believes backlog is
      empty and agents are idle
    - [belief:operator_needed] — room believes operator
      intervention or new privileged surface is needed *)

val tension_rules : Meta_cognition_types.tension_rule list
(** Three rules pinned:
    - [tension:masc_tool_blockage] (kind: policy_gap)
    - [tension:idle_backlog_empty] (kind: boredom)
    - [tension:path_validator_bug] (kind: blocker) *)

val desire_rules : Meta_cognition_types.desire_rule list
(** Four rules pinned:
    - [desire:task_seeding]
      (actionability: [operator_or_scheduler])
    - [desire:audit_surface]
      (actionability: [operator_or_platform])
    - [desire:operator_guidance] (actionability: [operator])
    - [desire:synthetic_exercise]
      (actionability: [room_or_operator])

    The actionability literals match
    {!Meta_cognition_interpret.operator_actionability}'s
    permitted set (cycle 89) so the snapshot pipeline can
    route these into the dashboard's
    [Operator_desire] cascade. *)

(** {1 Source predicates}

    Two hidden-by-default predicates (out of ~6 internal
    rule-body predicates) are exposed because
    {!Meta_cognition_snapshot} uses them outside the rule
    tables: tool-block correlation counting and operator-need
    pre-filtering. *)

val tool_block_support :
  Meta_cognition_types.source -> bool
(** [tool_block_support source] returns [true] iff [source]
    matches one of the tool-block support signals AND does
    not also match a challenge signal.  The "support iff not
    challenged" asymmetry is intentional — a single source
    that mentions both sides is read as "advancing the
    discussion", not as evidence for the support side.

    Used by {!Meta_cognition_snapshot} to count board-wide
    tool-block correlations independently of the rule
    pipeline. *)

val operator_need_support :
  Meta_cognition_types.source -> bool
(** [operator_need_support source] returns [true] iff [source]
    matches one of the operator-need keywords (English +
    Korean).  Used by {!Meta_cognition_snapshot} to pre-filter
    operator-need-tagged sources before running the desire
    cascade. *)

val classify_interaction_text : string -> string option
(** [classify_interaction_text text] returns the canonical
    interaction kind for an interaction-comment text.

    {2 Decision order (pinned, first match wins)}

    | Keyword set | Returns |
    |---|---|
    | "correction" / "corrected" / "retracted" / "withdrawn" / "withdrew" / "amendment" / "정정" / "철회" | [Some "corrects"] |
    | "contradicts" / "however" / "disagree" / "incomplete" / "not wrong" / "ambiguity" / "question" / "반대" / "불일치" | [Some "challenges"] |
    | "corroborated" / "confirmed" / "consistent with" / "aligns with" / "agreed" / "agree" / "endorsed" / "support" / "accept the findings" / "confirms" | [Some "corroborates"] |
    | "acknowledged" / "reviewed" / "accepted" | [Some "acknowledges"] |
    | otherwise | [None] |

    Korean signals appear in the first two buckets only — a
    historical artefact of the original keeper transcript
    corpus where the corrects / challenges signals were the
    most often expressed in mixed Korean / English notes.
    Pinning at the contract seam: a future "more Korean
    keywords" PR must touch this contract. *)
