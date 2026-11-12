(** A Keeper wake schedule that becomes due when the checks of a commit end.

    [until_github_run] names one Actions run, but the checks of a commit are
    several runs, and a Keeper knows the commit it pushed, not the run numbers.
    A schedule created with [until_github_checks] names the commit. It keeps its
    due time as the fallback and gains a second trigger: when every check run of
    that commit has completed, the server moves the due time to now. The wake
    then travels the schedule's own path, as for {!Schedule_run_watch}, and this
    module keeps no state of its own. The watch lives in the Keeper wake payload
    body as [until_github_checks]; the row is the only record of it.

    The checks of a commit are the runs made by a [push], a [pull_request] or a
    [workflow_run] event. A run made by a review, a label or a hand
    ([pull_request_review], [pull_request_target], [workflow_dispatch], ...) is a
    new happening, not a check of the commit: on the 60 most recent pull request
    heads of jeong-sik/masc, 6 had an instant where every run made so far had
    ended and a check run was still to come, because an approval run had ended
    first (docs/evidence/check-wake-harness-2026-11). The check runs alone had no
    such instant. The commit is read as a full sha, so no short sha can be read
    as another commit. *)

(** A full commit sha: 40 hexadecimal digits, kept in lower case. *)
type sha

val sha_of_string : string -> (sha, string) result
val sha_to_string : sha -> string

type target =
  { repo : Schedule_run_watch.repo
  ; sha : sha
  }

val target_of_commit_url : string -> (target, string) result
(** Reads [https://github.com/<owner>/<repo>/commit/<40 hexadecimal digits>]. A
    query string or fragment is ignored. Any other URL, and a short sha, is an
    error that names the accepted shape. *)

val target_url : target -> string
val describe_target : target -> string

val target_to_yojson : target -> Yojson.Safe.t
(** The payload field value: [{repo, sha}]. *)

val target_of_yojson : Yojson.Safe.t -> (target, string) result
(** Strict: an unknown field, a repository that is not [owner/name] and a sha
    that is not 40 hexadecimal digits are errors. *)

(** The [event] that made a workflow run. A value that is not one of the three
    that make the checks of a commit is kept as it came. *)
type event =
  | Push
  | Pull_request
  | Workflow_run
  | Other_event of string

val event_of_string : string -> event
val event_to_string : event -> string

val is_check_event : event -> bool
(** [true] for {!Push}, {!Pull_request} and {!Workflow_run}. *)

type check_run =
  { workflow : string
  ; event : event
  ; conclusion : Schedule_run_watch.conclusion option
        (** [None] when GitHub reports the run completed with a null conclusion. *)
  }

type observation =
  | Not_settled
      (** No check run is there yet, or one of them has not completed. *)
  | Settled of check_run list
      (** One or more check runs, all completed, in the order GitHub listed
          them. They are not picked or merged: a run that was cancelled by a
          later one is in the list with its own conclusion. *)

val observation_of_runs_json : ?allow_incomplete:bool -> target -> Yojson.Safe.t -> (observation, string) result
(** Reads the answer of
    [GET /repos/{owner}/{repo}/actions/runs?head_sha={sha}&per_page=100]. Every
    run must carry the [head_sha] of the target: an error body has no runs, and
    a list for another commit must not read as this one. By default an answer whose
    [total_count] is more than the runs it carries is {!Not_settled}: the reader
    must fetch the remaining pages before deciding. With [~allow_incomplete:true],
    only the runs in this page are judged; the caller must still cover
    [total_count] and require every page to settle before returning {!Settled}.
    A run [status] that is absent, null or not a string is an error. *)

(** What the wake tells the Keeper. *)
type settled =
  | Checks_completed of check_run list
  | Checks_unreadable of Schedule_run_watch.read_failure
      (** The wake comes early because waiting cannot work: the Keeper is told
          why and checks the runs itself. *)

val wake_message : target -> settled -> original:string -> string
(** The outcome, one line per check run, and the commit URL first, then the
    Keeper's own message unchanged. *)

val watch_field : string
(** ["until_github_checks"], the Keeper wake payload body field. *)

val watch_of_body : (string * Yojson.Safe.t) list -> (target option, string) result
(** The watch in the body of a Keeper wake payload. [Ok None] when the body has
    no [until_github_checks] field. *)

val watch_of_payload : Yojson.Safe.t -> (target option, string) result
(** The watch of a payload. [Ok None] for a payload without one, and for every
    payload that is not a Keeper wake. *)

val settle_payload : Yojson.Safe.t -> target -> settled -> (Yojson.Safe.t, string) result
(** The payload with the watch removed and {!wake_message} in place of the
    message. The removed watch is what stops a second wake. *)

type verdict =
  | Woken of settled
  | Waiting_for_checks
  | Waiting_to_read of Schedule_run_watch.read_failure
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
  read:(target -> (observation, Schedule_run_watch.read_failure) result) ->
  (outcome list, string) result
(** One pass over the [Scheduled] one-shot Keeper wakes that carry a checks
    watch, as {!Schedule_run_watch.tick} is one over the run watches. Each
    distinct commit is read once, however many schedules wait on it, and after a
    rate-limited answer no further read is made in the pass. *)
