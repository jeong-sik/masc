(** Keeper-layer name for {!Runtime_attempt_dispatch}.

    The sum itself lives in [masc_types] so the task-side reviewer hook
    ([Anti_rationalization.run_llm_reviewer_fn]) can name it without a
    dependency on the keeper library. The manifest equation below makes
    [Keeper_attempt_dispatch.Dispatched] and
    [Runtime_attempt_dispatch.Dispatched] the same constructor, so keeper
    callers and the task-side hook exchange values without conversion. *)

type t = Runtime_attempt_dispatch.t =
  | Dispatched
      (** The candidate's provider or client was invoked. The attempt error,
          if any, is that candidate's answer. *)
  | Rejected_before_dispatch
      (** The walk refused the candidate without invoking it. The attempt
          error names the refusal; no provider saw the request. *)

(** Log rendering: ["dispatched"] or ["rejected_before_dispatch"]. *)
val to_string : t -> string
