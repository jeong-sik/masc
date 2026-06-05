
(** Board_core_classify — post visibility / kind converters and
    classification.

    Two responsibilities:
    - Type / string round-trip for [visibility] and [post_kind].
    - Legacy migration heuristics ({!legacy_migrate_post_kind}) +
      classification reason rendering ({!post_classification_reason}).

    {b Include runtime:} this module starts with
    [include Board_types], so consumers using
    [include Board_core_classify] (notably {!Board_core}) inherit
    every {!Board_types} surface entry.  Internal helpers
    ([contains_substring], 5 yojson [meta_*] / [judgment_*]
    helpers) stay private.  {!take} is exposed because {!Board_core}
    uses it via include.

    {b RFC-0089 §4-3 G2:} legacy [String.starts_with] / [List.mem]
    author classifiers ([legacy_author_looks_automation] /
    [legacy_system_board_author]) are removed.  Author classification
    now flows through the typed {!author_kind} variant exposed below;
    boundary parse via {!classify_author} happens once and callers
    pattern-match on the variant. *)

include module type of struct
  include Board_types
end

(** {1 List utility (include runtime)} *)

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
    allowed-values set in the [board_tool] argv schema (#8392). *)

(** {1 Post kind round-trip} *)

val post_kind_to_string : post_kind -> string
(** [post_kind_to_string k] returns ["direct"] (Human_post) /
    ["automation"] / ["system"]. *)

val post_kind_of_string : string -> post_kind option
(** [post_kind_of_string s] accepts ["direct"] / ["automation"] /
    ["system"]; returns [None] for unrecognised inputs. *)

(** {1 Author classification (RFC-0089 §4-3 G2)} *)

(** Re-export of {!Board_types.automation_label} (relocated there so the
    board metric hook surface can reference it without a dependency
    cycle). The type equation keeps existing users compiling unchanged. *)
type automation_label = Board_types.automation_label =
  | Auto_prefixed       (** Author starts with ["auto-"]. *)
  | Qa_prefixed         (** Author starts with ["qa-"]. *)
  | Researcher_named    (** Author contains ["researcher"]. *)
  | Harness_named       (** Author contains ["harness"]. *)
  | Smoke_named         (** Author contains ["smoke"]. *)
  | Probe_named         (** Author contains ["probe"]. *)

type system_actor =
  | Ecosystem
  | Operator

type author_kind =
  | Human_author
  | Automation_author of automation_label
  | System_author of system_actor

val classify_author : string -> author_kind
(** [classify_author author] derives the typed {!author_kind} from a
    lowercased author string.  Resolution order matches the legacy
    bool-OR chain (system list -> "auto-" / "qa-" prefix -> researcher
    / harness / smoke / probe substring -> [Human_author] fallback).

    Caller MUST pre-lowercase the author (callers historically called
    [String.lowercase_ascii] before the legacy helpers; that contract
    is preserved). *)

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

    + System author (one of the platform/system aliases) ->
      [System_post].
    + Agent board-post provenance source -> [Automation_post].
    + Internal visibility + [expires_at > 0.0] + non-empty hearth
      starting with ["mdal"] or containing ["harness"] ->
      [Automation_post].
    + Author matches the legacy automation heuristic (prefixes
      ["auto-"] / ["qa-"], or contains ["researcher"] / ["harness"] /
      ["smoke"] / ["probe"]) -> [Automation_post] and emits the
      legacy-migration metric through [Board_metrics_hooks].
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
      / Human_post + other / Automation_post + agent board post /
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
