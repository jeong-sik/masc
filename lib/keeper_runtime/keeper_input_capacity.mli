(** Typed recovery policy for OAS serving-constraint admission failures.

    MASC consumes the provider-neutral evidence only. Provider/model names,
    endpoint URLs, HTTP prose, and tokenizer guesses are intentionally absent. *)

type recovery =
  | Compact_to_accepted_through of int
  | Failover_only

val recovery_of_reason : Agent_sdk.Retry.input_capacity_reason -> recovery

val should_try_next_runtime : Agent_sdk.Error.sdk_error -> bool
(** [true] only for typed [Api (InputCapacity _)]. Every such failure is local
    to the resolved runtime attempt, so another frozen lane candidate may
    proceed without reclassifying a generic invalid request. *)

val compaction_limit : Agent_sdk.Error.sdk_error -> int option
(** [Some n] only when current evidence proves input at or below [n] was
    accepted. [None] means compaction cannot repair the typed failure
    (expired/future evidence or unavailable measurement). *)
