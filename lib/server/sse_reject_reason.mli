(** Sse_reject_reason — closed sum for SSE-connect rate-limit rejects.

    Replaces the prior [Error (string * float)] tuple where the string
    was constrained-in-practice to two values ({"session_cooldown",
    "window_limit"}) but had no type-level guarantee.  The metric label
    on [metric_sse_rejects] now derives from a closed variant so adding
    a third gate becomes a single edit instead of a string-literal
    sprinkle. *)

type t =
  | Session_cooldown (** Per-session reconnect cooldown window unmet. *)
  | Window_limit
  (** Per-session connect-count threshold over the
                          sliding window. *)

(** Stable wire format for the [reason] label on
    [metric_sse_rejects].  Returns the exact strings the legacy
    code emitted: ["session_cooldown"] / ["window_limit"]. *)
val to_label : t -> string
