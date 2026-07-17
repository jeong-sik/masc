(** Durable Board-attention judgment boundary.

    A candidate is persisted before any asynchronous model call. Its lifecycle
    is [Pending -> Judged -> Consumed] on the happy path. A retryable judge or
    delivery failure moves it to [Deferred] instead of leaving it silently
    Pending forever; a permanent judge rejection, an exhausted retry budget, or
    stale backlog moves it to the absorbing [Terminal_failed] state. Legacy
    ledger rows using only [Pending]/[Judged]/[Consumed] load unchanged — this
    revision only adds new row shapes, it never changes the existing ones. *)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable
  | Worker_unavailable
  (** Retained only for legacy ledger rows written before the retry-gate
      redesign. New rows are never written with this kind. *)

type retryable_failure =
  { kind : retryable_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; runtime_id : string
  ; judged_at : float
  }

type delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

type pending_state = { last_failure : retryable_failure option }

type judged_state =
  { judgment : judgment
  ; last_failure : retryable_failure option
  }

type consumed_state =
  { judgment : judgment
  ; delivery : delivery
  ; consumed_at : float
  }

(** How long to wait before the deferred work is due, and how many attempts
    (judge or delivery, whichever this row is deferring) have already failed. *)
type retry_gate =
  { not_before : float
  ; attempts : int
  }

(** What a due [Deferred] row resumes: a fresh judge call, or a durable-enqueue
    retry carrying the judgment already produced (never re-judge a Relevant
    verdict just because its delivery failed). *)
type deferred_resume =
  | Resume_judge
  | Resume_delivery of judgment

type deferred_state =
  { resume : deferred_resume
  ; failure : retryable_failure
  ; retry : retry_gate
  }

(** Provider/judge rejection classes that are never worth retrying: retrying
    without operator intervention (credential fix, quota top-up, request
    reshaping) reproduces the identical rejection forever. *)
type permanent_class =
  | Auth
  | Authorization
  | Payment_required
  | Invalid_request
  | Not_found
  | Context_overflow

type terminal_reason =
  | Judge_rejected of
      { class_ : permanent_class
      ; detail : string
      }
  | Retry_budget_exhausted of
      { last : retryable_failure
      ; attempts : int
      }
  | Expired_backlog of
      { age_s : float
      ; max_age_s : float
      }

type terminal_state =
  { reason : terminal_reason
  ; failed_at : float
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Deferred of deferred_state
  | Consumed of consumed_state
  | Terminal_failed of terminal_state

type candidate =
  { candidate_id : string
  ; keeper_name : string
  ; signal : Board_dispatch.board_signal
  ; judgment_request : Yojson.Safe.t
  ; recorded_at : float
  ; status : status
  }

type record_result =
  | Recorded of candidate
  | Duplicate of candidate
  | Record_error of string

exception Candidate_unavailable of string

val prompt_name : string
val retryable_failure_kind_to_string : retryable_failure_kind -> string
val retryable_failure_kind_of_string : string -> retryable_failure_kind option
val delivery_to_string : delivery -> string
val delivery_of_string : string -> delivery option
val signal_to_yojson : Board_dispatch.board_signal -> Yojson.Safe.t

val of_board_evidence :
  meta:Keeper_meta_contract.keeper_meta ->
  recorded_at:float ->
  signal:Board_dispatch.board_signal ->
  post:Board.post ->
  comments:Board.comment list ->
  (candidate, string) result

val of_board_signal :
  meta:Keeper_meta_contract.keeper_meta ->
  recorded_at:float ->
  Board_dispatch.board_signal ->
  candidate Keeper_world_observation_board_signal.board_read
(** Reads the complete persisted post and comment set. Board failures remain
    typed [Unavailable] and no partial candidate is synthesized. *)

val candidate_to_json : candidate -> Yojson.Safe.t
val candidate_of_json : Yojson.Safe.t -> (candidate, string) result

val load_candidates :
  base_path:string -> keeper_name:string -> (candidate list, string) result

val record : base_path:string -> candidate -> record_result

val record_judgment :
  base_path:string -> candidate -> judgment -> (candidate, string) result

(** Retry/expiry policy for {!process_with_judge}. Owned by the caller
    (production: {!Keeper_config} via [Keeper_board_attention_worker]) so this
    module stays a pure state machine with no config dependency. *)
type retry_policy =
  { retry_base_sec : float
  ; retry_max_sec : float
  ; max_attempts : int
  ; max_pending_age_sec : float
  }

(** Typed classification of a judge attempt's SDK failure: retryable (with an
    optional provider-supplied retry-after hint) or permanently rejected. *)
type judge_error =
  | Judge_retryable of
      { failure : retryable_failure
      ; retry_after : float option
      }
  | Judge_permanent of
      { class_ : permanent_class
      ; detail : string
      }

val classify_judge_sdk_error : Agent_sdk.Error.sdk_error -> judge_error
(** Exhaustive classification over {!Agent_sdk.Error_domain.of_sdk_error}'s
    polymorphic variant. Provider errors split into retryable vs. permanent;
    every non-provider SDK domain (tool/agent/config/mcp/serialization/io/
    orchestration/internal) is retryable — those surface while attempting the
    same provider call and are environment/operator-fixable, not a judge
    verdict, so the same attempt budget applies rather than permanently
    rejecting the candidate on infrastructure noise. *)

val run_judge : base_path:string -> candidate -> (judgment, judge_error) result
(** Runs one judge attempt: resolves the structured-judge runtime, renders the
    prompt, calls the provider, and parses the structured verdict. Every
    failure surface (runtime resolution, prompt render, provider call,
    response parse) is classified into {!judge_error}; the provider-call
    surface goes through {!classify_judge_sdk_error}, the rest are always
    retryable. *)

val terminalize_expired :
  base_path:string -> now:float -> policy:retry_policy -> candidate -> (candidate, string) result
(** Pre-dispatch filter: if [candidate] is [Pending] or [Deferred] and older
    than [policy.max_pending_age_sec] (measured from [candidate.recorded_at]),
    terminalizes it with [Expired_backlog] and never calls a judge. Otherwise
    returns [Ok candidate] unchanged, including for [Judged]/[Consumed]/
    [Terminal_failed] (expiry never applies to those). {!process_with_judge}
    applies the identical check internally; this lets a dispatcher retire
    stale backlog during its eligibility scan without spending a worker slot
    on it. *)

val is_eligible_for_dispatch : now:float -> candidate -> bool
(** [true] for [Pending], [Judged], or a [Deferred] row whose retry gate is
    due ([not_before <= now]). [false] for [Consumed], [Terminal_failed], and
    a [Deferred] row that is not yet due. Callers should apply
    {!terminalize_expired} first so an expired row is never dispatched. *)

val process_with_judge :
  base_path:string ->
  now:(unit -> float) ->
  policy:retry_policy ->
  judge:(candidate -> (judgment, judge_error) result) ->
  candidate ->
  (candidate, string) result
(** Testable state-machine boundary. [Pending]/due [Deferred{Resume_judge}]
    call [judge]; a retryable failure defers with capped-exponential backoff
    (provider retry-after hint wins when present) until [policy.max_attempts]
    is spent, then terminalizes with [Retry_budget_exhausted]; a permanent
    failure terminalizes immediately with [Judge_rejected]. [Judged]/due
    [Deferred{Resume_delivery}] attempt durable delivery without ever calling
    [judge] again; a storage/identity failure defers the same way, preserving
    the judgment. [Pending]/[Deferred] older than [policy.max_pending_age_sec]
    terminalize with [Expired_backlog] before any judge call. A [Deferred] row
    not yet due, and [Consumed]/[Terminal_failed], are returned unchanged.
    Production uses the configured judge through
    [Keeper_board_attention_worker], which owns scheduling: this module has
    no fiber-forking or scheduling API of its own. *)
