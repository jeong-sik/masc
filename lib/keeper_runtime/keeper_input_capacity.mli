(** Provider-neutral projection of an OAS-validated compactable input bound.

    MASC consumes the provider-neutral evidence only. Provider/model names,
    endpoint URLs, HTTP prose, and tokenizer guesses are intentionally absent. *)

val compaction_limit : Agent_sdk.Error.sdk_error -> int option
(** [Some n] only when OAS returns a typed [Input_rejected] or
    [Boundary_unknown] reason carrying [accepted_through = n]. MASC does not
    re-evaluate evidence time. [None] means OAS classified the evidence as
    expired/not-yet-valid, or token measurement was unavailable. *)
