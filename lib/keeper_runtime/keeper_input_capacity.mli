(** Provider-neutral projection of a proven compactable input bound.

    MASC consumes the provider-neutral evidence only. Provider/model names,
    endpoint URLs, HTTP prose, and tokenizer guesses are intentionally absent. *)

val compaction_limit : Agent_sdk.Error.sdk_error -> int option
(** [Some n] only when current evidence proves input at or below [n] was
    accepted. [None] means compaction cannot repair the typed failure
    (expired/future evidence or unavailable measurement). *)
