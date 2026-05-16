(** Keeper_user_visible_reply_source — closed sum naming the five
    paths through {!Keeper_text_processing.user_visible_reply_text}.

    The function picks the first non-empty source from a cascade:
    {ol
    {- Stripped raw reply (markup + [STATE] removed)}
    {- Caller-supplied [fallback] argument}
    {- [progress] field of the parsed [STATE] snapshot}
    {- [goal] field of the parsed [STATE] snapshot}
    {- Hardcoded literal ["State updated."]}}

    Until this module existed, every callers' user-visible reply
    landed on one of those five paths with no audit trail.  Path 5
    in particular is the operational signal that the LLM produced
    nothing usable — the user sees a meaningless string and
    operators had no way to measure how often that happened. *)

type t =
  | Stripped_raw
      (** Path 1: the markup-/STATE-stripped raw reply was
          non-empty. Normal path. *)
  | Fallback_param
      (** Path 2: stripped raw was empty, but the caller passed a
          non-empty [?fallback] argument. *)
  | State_snapshot_progress
      (** Path 3: only the [STATE] snapshot's [progress] field
          carried usable text. *)
  | State_snapshot_goal
      (** Path 4: only the [STATE] snapshot's [goal] field carried
          usable text (progress was [None]). *)
  | Hardcoded_default
      (** Path 5: every source was empty; the literal
          ["State updated."] was returned.  Rising rate of this
          variant is the operational signal that the LLM is
          producing no usable reply at all. *)

val to_label : t -> string
