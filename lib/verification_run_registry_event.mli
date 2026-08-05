(** JSONL event type for verification run registry persistence (RFC-0361 D4).

    Every state-changing operation on {!Verification_run_registry.t} appends one
    event line to disk. On server boot the log is replayed to restore recent
    run history. *)

(** How a completion-authority review ended.

    A closed sum rather than an [ok : bool] plus free-text: each constructor
    answers a distinct operational question that a boolean collapses.
    [Contract_rejected] and [Rejected] both commit [Verdict_rejected], but only
    the latter means the configured LLM produced that verdict — an operator
    reading "rejected" cannot otherwise tell whether the judge ran at all.
    [Commit_failed] carries a decided verdict that never reached the durable
    task state, which is a different failure from the judge declining to
    produce one ([Not_reviewed]). *)
type outcome =
  | Approved
  | Rejected of { reason : string }
      (** The configured LLM returned REJECT and the verdict committed. *)
  | Contract_rejected of { detail : string }
      (** The agent rejected before the LLM ran (evidence contract invalid). *)
  | Not_reviewed of { gate : string; detail : string }
      (** The review ran but yielded no verdict — invalid verdict shape or an
          unavailable evaluator. [gate] is
          {!Task.Anti_rationalization.gate_to_string}. *)
  | Commit_failed of { detail : string }
      (** A verdict was decided but [Workspace.commit_verdict_r] failed, so the
          Task stayed nonterminal and the review will be retried. *)
  | Raised of { detail : string }
      (** The review raised. Structural cancellation is re-raised by the caller
          and never recorded here. *)

type t =
  | Register of
      { verification_id : string
      ; task_id : string
      ; producer : string
      ; authority_kind : string
      ; authority_actor : string
      ; started_at : float
      }
  | Complete of
      { verification_id : string
      ; outcome : outcome
      ; evaluator_runtime : string option
          (** Known only when the review reached the evaluator; [None] for
              [Contract_rejected] and [Raised]. *)
      ; elapsed_s : float
      }

val outcome_label : outcome -> string
(** Stable wire label, one per constructor:
    ["approved" | "rejected" | "contract_rejected" | "not_reviewed" |
     "commit_failed" | "raised"]. The single place the outcome vocabulary is
    defined, shared by persistence, the HTTP surface and the dashboard so it
    never drifts. *)

val to_yojson : t -> Yojson.Safe.t
(** Canonical JSON object for one event. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse an event from a JSON object. Unknown event kinds and unknown outcome
    labels are [Error] rather than a permissive default, so a shape this module
    did not write is visible instead of silently replayed as something else. *)

val to_jsonl : t -> string
(** Single JSONL line (JSON object + trailing newline). *)
