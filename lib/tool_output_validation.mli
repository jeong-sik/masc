
(** Tool_output_validation — Memory-protection cap.

    Context budget management belongs to OAS [context_reducer].
    This module only prevents OOM from unbounded tool output.

    @since #5807 — simplified to boundary-respecting cap in #5821. *)

(** Hard cap in characters.  Any output beyond this is capped with
    a trailing marker.  Intentionally generous (64 KB): guards against
    runaway allocations, not against context window pressure. *)
val max_output_chars : int

(** Cap a tool output string.  Returns unchanged if within
    [max_output_chars]; otherwise truncates and appends a marker. *)
val cap : string -> string

(** Post-hook for [Tool_dispatch.register_post_hook].
    Applies [cap] to [masc_*] tools that go through the dispatch
    pipeline. *)
val post_hook : Tool_result.t -> Tool_result.t

(** Install the post-hook into [Tool_dispatch]. Idempotent. *)
val install : unit -> unit
