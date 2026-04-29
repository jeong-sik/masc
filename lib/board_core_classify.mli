(** Board_core_classify — post visibility / kind converters and
    classification.

    Two responsibilities:
    - Type / string round-trip for [visibility] and [post_kind].
    - Legacy migration heuristics ({!legacy_migrate_post_kind}) +
      classification reason rendering ({!post_classification_reason}).

    {b Include cascade:} this module starts with
    [include Board_types], so consumers using
    [include Board_core_classify] (notably {!Board_core}) inherit
    every {!Board_types} surface entry.  Internal helpers
    ([contains_substring], [legacy_author_looks_automation],
    [legacy_system_board_author], 5 yojson [meta_*] / [judgment_*]
    helpers) stay private.  {!take} is exposed because {!Board_core}
    uses it via include. *)

include module type of struct
  include Board_types
end

(** {1 Prometheus counter (#9919)} *)

val legacy_migrate_post_kind_metric : string
(** Pinned literal: ["masc_board_legacy_migrate_post_kind_total"].

    Replaces the prior degenerate
    [Heuristic_metrics.record \[raw=1.0; threshold=0.5\]] emit at the
    legacy author-heuristic migration site.  Labelled by [author] so
    operators can see which legacy authors still drive the migration
    path.  See {!legacy_migrate_post_kind} for the call site. *)

(** {1 List utility (include cascade)} *)

val take : int -> 'a list -> 'a list
(** [take n lst] returns the first [n] elements of [lst] (or all of
    [lst] if shorter than [n]).  Returns [\[\]] when [n <= 0].
    Exposed because {!Board_core} uses it via [include]. *)

(** {1 Visibility round-trip} *)

val visibility_to_string : visibility -> string
(** [visibility_to_string v] returns ["public"] / ["unlisted"] /
    ["internal"] / ["direct"]. *)

val visibility_of_string : string -> visibility option
(** [visibility_of_string s] is the inverse of
    {!visibility_to_string}; returns [None] for unrecognised
    inputs. *)

val all_visibilities : visibility list
(** Static list of every {!visibility} constructor in declaration
    order.  Used by JSON-schema generators (see #8392 for the same
    drift class as task_status / agent_status / agent_role).  Adding
    a 5th constructor will fail compilation in
    {!visibility_to_string} and the test asserts. *)

val valid_visibility_strings : string list
(** [List.map visibility_to_string all_visibilities].  Used as the
    allowed-values set in the [tool_board] argv schema (#8392). *)

(** {1 Post kind round-trip} *)

val post_kind_to_string : post_kind -> string
(** [post_kind_to_string k] returns ["direct"] (Human_post) /
    ["automation"] / ["system"]. *)

val post_kind_of_string : string -> post_kind option
(** [post_kind_of_string s] accepts ["direct"] {b and} ["human"]
    (both -> [Human_post]) for backward compat; returns [None] for
    unrecognised inputs. *)

(** {1 Legacy migration} *)

val legacy_migrate_post_kind :
  meta_json:Yojson.Safe.t option ->
  author:string ->
  visibility:visibility ->
  expires_at:float ->
  hearth:string option ->
  post_kind
(** [legacy_migrate_post_kind ~meta_json ~author ~visibility
      ~expires_at ~hearth] derives the canonical [post_kind] for
    legacy posts that lack an explicit one.  Decision priority
    (first match wins):

    + System author (one of \["ecosystem"; "keeper";
      "keeper-alert-bot"; "keeper-system"; "operator";
      "team-session"\]) -> [System_post].
    + [meta_json.source = "keeper_board_post"] -> [Automation_post].
    + Internal visibility + [expires_at > 0.0] + non-empty hearth
      starting with ["mdal"] or containing ["harness"] ->
      [Automation_post].
    + Author matches the legacy automation heuristic (prefixes
      ["auto-"] / ["qa-"], or contains ["researcher"] / ["harness"] /
      ["smoke"] / ["probe"]) -> [Automation_post] +
      {!legacy_migrate_post_kind_metric} counter increment with the
      [author] label.
    + Otherwise -> [Human_post]. *)

(** {1 Classification accessors} *)

val classify_post_kind : post -> post_kind
(** [classify_post_kind p] is the trivial accessor [p.post_kind]
    — exposed as a contract surface so future migrations
    (e.g. computed [post_kind] from a [post.classification] field)
    do not require caller updates. *)

val post_classification_reason : post -> string
(** [post_classification_reason p] renders the human-readable reason
    why [p] has its current [post_kind].  Resolution order:

    + [meta_json.classification_reason] (string).
    + [meta_json.judgment.summary | reason | classification_reason]
      (string-or-object).
    + Fallback templates per
      [(post_kind, meta_json.source)] pair (Human_post + dashboard
      / Human_post + other / Automation_post + keeper_board_post /
      Automation_post + dashboard / Automation_post + legacy
      heuristic / System_post / etc.). *)

val post_matches_filters :
  exclude_system:bool ->
  exclude_automation:bool ->
  post ->
  bool
(** [post_matches_filters ~exclude_system ~exclude_automation p] is
    true iff [p.post_kind] is not excluded by either flag.
    Composed conjunctively — both flags are AND'd. *)

(** {1 Reclassify report} *)

type reclassify_report = {
  backend : string;
  dry_run : bool;
  scanned : int;
  changed : int;
  unchanged : int;
  skipped : int;
  apply_failures : int;
  changed_post_ids : string list;
}
(** Output of bulk reclassification operations.  Used by both the
    filesystem and PG backends. *)

val reclassify_report_to_yojson : reclassify_report -> Yojson.Safe.t
(** Hand-written serialiser (no PPX) — kept so the JSON shape stays
    stable across refactors. *)
