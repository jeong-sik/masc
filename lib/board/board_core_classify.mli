
(** Board_core_classify — post visibility / kind converters and
    classification accessors.

    Two responsibilities:
    - Type / string round-trip for [visibility] and [post_kind].
    - Classification reason rendering ({!post_classification_reason}).

    {b Include runtime:} this module starts with
    [include Board_types], so consumers using
    [include Board_core_classify] (notably {!Board_core}) inherit
    every {!Board_types} surface entry.  Internal helpers
    ([contains_substring], 5 yojson [meta_*] / [judgment_*]
    helpers) stay private.  {!take} is exposed because {!Board_core}
    uses it via include.

    Persisted rows must carry an explicit [post_kind].  Missing or
    malformed [post_kind] is a persistence-shape failure, not a local
    inference problem. *)

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
      Automation_post + dashboard / AutomationPost explicit contract /
      System_post / etc.). *)

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
  invalid_post_ids : string list;
}
(** Output of the retired post-kind reclassification scan.  [changed] is
    always [0]; [invalid_post_ids] records rows that lack a valid explicit
    [post_kind] without locally inferring a replacement. *)
