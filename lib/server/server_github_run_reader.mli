(** Reads GitHub Actions runs for {!Schedule_run_watch} and
    {!Schedule_checks_watch}: one run by id, or the runs of one commit.

    The GET goes to [api.github.com] with the token of the Keeper named by
    runtime.toml [\[repositories\] pr_reader] ({!Server_repository_pulls.rest_get}),
    resolved again on every read. Nothing is kept between reads. *)

val path_of_target : Schedule_run_watch.target -> string
(** [/repos/<owner>/<repo>/actions/runs/<id>], followed by [/attempts/<n>]
    when the target names an attempt. *)

val checks_path_of_target : Schedule_checks_watch.target -> string
(** [/repos/<owner>/<repo>/actions/runs?head_sha=<sha>&per_page=100]. *)

val interpret :
  now_s:float ->
  Schedule_run_watch.target ->
  Server_repository_pulls.response ->
  (Schedule_run_watch.observation, Schedule_run_watch.read_failure) result
(** What a recorded answer says about the target run. A 404 is
    {!Schedule_run_watch.Not_visible}: GitHub gives it for a run that does not
    exist and for a repository the reader's account cannot see, and a reader
    cannot tell them apart. A 403 or 429 that carries an exhausted limit or a
    [retry-after] is {!Schedule_run_watch.Rate_limited}, with the time GitHub
    gave, at most an hour after [now_s]. A body that is not JSON, or is not the
    target run, is {!Schedule_run_watch.Response_unreadable}. *)

val read :
  now:(unit -> float) ->
  http_get:Server_repository_pulls.http_get ->
  config:Workspace.config ->
  Schedule_run_watch.target ->
  (Schedule_run_watch.observation, Schedule_run_watch.read_failure) result
(** One read of the target run: {!Server_repository_pulls.rest_get} on
    {!path_of_target}, then {!interpret}. No declared reader, a declared
    reader that is not a configured Keeper and a reader of another host are
    {!Schedule_run_watch.Reader_unavailable}. A declaration or a token that
    could not be read is {!Schedule_run_watch.Reader_not_ready}, which can
    pass. A request that did not complete is
    {!Schedule_run_watch.Transport_failed}. *)

val interpret_checks :
  now_s:float ->
  Schedule_checks_watch.target ->
  Server_repository_pulls.response ->
  (Schedule_checks_watch.observation, Schedule_run_watch.read_failure) result
(** What a recorded answer says about the checks of the target commit. The
    status rules are those of {!interpret}. GitHub answers 200 with no runs for
    a commit it holds no run of, so that case is
    {!Schedule_checks_watch.Not_settled}, not {!Schedule_run_watch.Not_visible}:
    a schedule that waits for a commit no workflow ran on keeps its fallback
    time. A body that is not JSON, is not a runs list or holds a run of another
    commit is {!Schedule_run_watch.Response_unreadable}. *)

val read_checks :
  now:(unit -> float) ->
  http_get:Server_repository_pulls.http_get ->
  config:Workspace.config ->
  Schedule_checks_watch.target ->
  (Schedule_checks_watch.observation, Schedule_run_watch.read_failure) result
(** All pages of the runs of the target commit, with the account and the
    failures of {!read}. Every run has an integer [id]. Pages are fetched until
    [total_count] is covered, then every page is read again to check that its
    membership has not changed. A changed [total_count], duplicate id, excess id
    count, changed membership in any page, incomplete page, or an empty set of
    actual check runs keeps {!Schedule_checks_watch.Not_settled}. Only unique
    completed check runs from every page become {!Schedule_checks_watch.Settled}. *)
