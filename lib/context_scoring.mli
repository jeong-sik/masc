(** Context_scoring — Shared importance scoring for MASC messages.

    Single source of truth for message importance scoring used by both
    [Context_manager] and [Context_compact_oas].

    @since 2.111.0 *)

(** Prefix for compacted memory summaries. *)
val memory_summary_prefix : string

(** Prefix for goal injection messages. *)
val goal_prefix : string

(** Check if [s] starts with [prefix]. *)
val starts_with : prefix:string -> string -> bool

(** Score a list of messages by importance.

    Returns [(index, score)] pairs where score is in [\[0.0, 1.0\]].
    Higher scores indicate more important messages.

    Messages starting with [memory_summary_prefix] or [goal_prefix]
    receive a minimum score of 0.95 (sticky memory). *)
val score_messages : Agent_sdk.Types.message list -> (int * float) list
