(** Keeper_user_visible_reply_source — closed sum naming the three
    paths through {!Keeper_text_processing.user_visible_reply_text}.

    The function picks the first non-empty source from a runtime:
    {ol
    {- Stripped raw reply}
    {- Caller-supplied [fallback] argument}
    {- Explicit no-content diagnostic}}

    Until this module existed, every callers' user-visible reply
    landed on one of those paths with no audit trail. The final path is
    the operational signal that the model produced no usable text. *)

type t =
  | Stripped_raw
      (** Path 1: the trimmed raw reply was non-empty. Normal path. *)
  | Fallback_param
      (** Path 2: stripped raw was empty, but the caller passed a
          non-empty [?fallback] argument. *)
  | Hardcoded_default
      (** Path 3: every source was empty; an explicit no-content diagnostic
          was returned. Rising rate of this
          variant is the operational signal that the LLM is
          producing no usable reply at all. *)

val to_label : t -> string
