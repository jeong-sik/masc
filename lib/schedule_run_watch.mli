(** A Keeper wake schedule that becomes due when a GitHub Actions run ends.

    A Keeper that waits for a run today either holds a turn in a [sleep] loop
    or schedules a wake at a guessed time. A schedule created with
    [until_github_run] keeps its due time as the fallback and gains a second
    trigger: when the run completes, the server moves the due time to now. The
    wake then travels the schedule's own path, so listing, cancelling,
    restarts and delivery are the schedule's, and this module keeps no state of
    its own. The watch lives in the Keeper wake payload body as
    [until_github_run]; the row is the only record of it. *)

(** [owner/name]. Each part holds letters, digits, ['-'], ['_'] or ['.'] and
    is neither [.] nor [..], so a repository name never changes the path of the
    URL it is put in. *)
type repo

val repo_of_string : string -> (repo, string) result
val repo_to_string : repo -> string

type target =
  { repo : repo
  ; run_id : int
  ; run_attempt : int option
      (** [Some n] waits for attempt [n] and no other. [None] waits for the
          run's latest attempt. *)
  }

val target_of_run_url : string -> (target, string) result
(** Reads [https://github.com/<owner>/<repo>/actions/runs/<run_id>], optionally
    followed by [/attempts/<n>]. A query string or fragment is ignored. Any
    other URL is an error that names the accepted shape. *)

val target_url : target -> string
val describe_target : target -> string

val target_to_yojson : target -> Yojson.Safe.t
(** The payload field value: [{repo, run_id}] and [run_attempt] when given. *)

val target_of_yojson : Yojson.Safe.t -> (target, string) result
(** Strict: an unknown or duplicated field, a non-integer id and a repository
    that is not [owner/name] are errors. *)

(** The values GitHub documents for a completed run's [conclusion]. A value
    outside the list is kept as it came. *)
type conclusion =
  | Success
  | Failure
  | Cancelled
  | Skipped
  | Timed_out
  | Neutral
  | Action_required
  | Stale
  | Startup_failure
  | Unrecognized of string

val conclusion_of_string : string -> conclusion
val conclusion_to_string : conclusion -> string

type observation =
  | Not_completed
  | Completed of conclusion option
      (** [None] when GitHub reports the run completed with a null conclusion. *)

val observation_of_run_json : target -> Yojson.Safe.t -> (observation, string) result
(** Reads the answer of [GET /repos/{owner}/{repo}/actions/runs/{run_id}] or of
    its [/attempts/{n}] form, which have the same shape. The answer must carry
    the [id] of the target run, and the [run_attempt] of the target when it
    names one: an error body has a [status] string too ([404]), and it would
    otherwise read as a run that has not finished. [status] [completed] is
    {!Completed}; any other string is {!Not_completed}. A [status] that is
    absent, null or not a string is an error, so a changed answer is not read
    as a run that never ends. *)

(** Why a read gave no observation. *)
type read_failure =
  | Not_visible
      (** 404: the repository or the run is not visible to the reader account. *)
  | Token_rejected
  | Forbidden
  | Rate_limited of { reset_at : float option }
  | Http_status of int
  | Transport_failed of string
  | Response_unreadable of string
  | Reader_unavailable of string
      (** No reader account is declared, or the declared one cannot read a
          github.com run. The text reaches the Keeper's wake message, so it
          names no file, Keeper or token. *)
  | Reader_not_ready of string
      (** The reader's declaration or token could not be read this time. The
          cause can be a file that is being written or a descriptor limit, so
          the text goes to the server log only. *)

val read_failure_to_string : read_failure -> string

val read_failure_is_permanent : read_failure -> bool
(** [true] when asking again gives the same answer until someone changes the
    declaration, the token or the run: not visible, rejected, forbidden, an
    unreadable body, no reader, and a status below 500 other than 408 and 425
    (3xx included: a redirect is not followed). [false] for a rate limit, a
    transport failure, a reader that is not ready, a 5xx status, 408 and 425. *)

(** What the wake tells the Keeper. *)
type settled =
  | Run_completed of conclusion option
  | Run_unreadable of read_failure
      (** The wake comes early because waiting cannot work: the Keeper is told
          why and checks the run itself. *)

val wake_message : target -> settled -> original:string -> string
(** The run's outcome and URL on the first lines, then the Keeper's own
    message unchanged. *)

val watch_field : string
(** ["until_github_run"], the Keeper wake payload body field. *)

val watch_of_body : (string * Yojson.Safe.t) list -> (target option, string) result
(** The watch in the body of a Keeper wake payload. [Ok None] when the body has
    no [until_github_run] field. *)

val watch_of_payload : Yojson.Safe.t -> (target option, string) result
(** The watch of a payload. [Ok None] for a payload without one, and for every
    payload that is not a Keeper wake. *)

val settle_payload : Yojson.Safe.t -> target -> settled -> (Yojson.Safe.t, string) result
(** The payload with the watch removed and {!wake_message} in place of the
    message. The removed watch is what stops a second wake. *)

val keeper_wake_body : Yojson.Safe.t -> (string * Yojson.Safe.t) list option
(** The body of a Keeper wake payload; [None] for any other payload. *)

val settle_body_payload :
  Yojson.Safe.t ->
  field:string ->
  message:(string -> string) ->
  (Yojson.Safe.t, string) result
(** The payload with the body field [field] removed and the message replaced by
    [message] applied to the original. {!settle_payload} is this with the run
    watch's field. Another kind of watch in the same body uses it to stop a
    second wake the same way. *)

val one_shot_scheduled : Schedule_domain.schedule_request -> bool
(** [true] for a row that is [Scheduled] and one-shot: the only rows a watch
    moves. *)

val make_due :
  Workspace_utils.config ->
  now:float ->
  runner_tick_sec:float ->
  Schedule_domain.schedule_request ->
  payload:Yojson.Safe.t ->
  (unit, string) result
(** Stores [payload] on the scanned row and moves its due time to the current
    second (an earlier due time stays). The update names the scanned instance,
    so a row that was replaced meanwhile keeps the replacement; the store also
    refuses a row that is running or finished. [Error] carries the store's
    reason. *)

val reads_once :
  key:('target -> string) ->
  read:('target -> ('observation, read_failure) result) ->
  'target -> ('observation, read_failure) result
(** A reader for one pass: each distinct [key] is read once, and after a
    {!Rate_limited} answer no further read is made. The tick of every kind of
    watch uses it. *)

type verdict =
  | Woken of settled
  | Waiting_for_run
  | Waiting_to_read of read_failure
      (** A read failed in a way that can pass; the fallback time still holds. *)
  | Not_woken of string
      (** The row changed, or the store refused the update. *)

type outcome =
  { schedule_id : string
  ; target : target option
        (** [None] when the stored watch field cannot be read. *)
  ; verdict : verdict
  }

val tick :
  Workspace_utils.config ->
  now:float ->
  runner_tick_sec:float ->
  read:(target -> (observation, read_failure) result) ->
  (outcome list, string) result
(** One pass over the [Scheduled] one-shot Keeper wakes that carry a watch.
    Each distinct target is read once, however many schedules wait on it, and
    after a {!Rate_limited} answer no further read is made in the pass. A
    completed run, or a failure that is permanent, moves that schedule's due
    time to the current second (an earlier due time stays) and replaces the
    payload as {!settle_payload} does; the schedule runner then wakes the
    Keeper as for any due schedule.
    The update names the instance that was scanned, so a schedule that was
    replaced while its run was being read keeps the replacement: the store
    refuses the update under its own lock. The store also refuses it for a row
    that is running or finished by then. Both are {!Not_woken}. [Error] only
    when the store cannot be read at the start of the pass. A ledger that
    becomes unreadable during the pass raises from the store; the caller
    handles it, and the outcomes of the rows already settled in that pass are
    not returned. *)
