(** Runs independent jobs in forked child processes and returns their results in
    the order the jobs were given.

    Every job runs in a process of its own and shares no memory with the others,
    so a job may call code that is not safe to run on several domains at once.
    A result comes back through [Marshal]: it must be plain data, with no
    closures, objects or custom blocks.

    Fork copies the calling process, so call {!map} before the process starts a
    second domain. {!map} flushes every open output channel before each fork,
    so text the caller printed earlier is not printed again by a child. *)

type failure =
  | Raised of string
      (** The job raised, or the fork for it failed. The text is
          [Printexc.to_string] of the exception. *)
  | Died of Unix.process_status
      (** The process ended without handing back a result: a signal ended it,
          or it exited without writing one. *)
  | Never_ran
      (** No result was recorded for the job. Not expected; reported instead of
          dropping the job from the list. *)

val failure_to_string : failure -> string

val map :
  jobs:int ->
  ?on_start:(int -> unit) ->
  ?on_result:(int -> ('a, failure) result -> unit) ->
  (unit -> 'a) list ->
  ('a, failure) result list
(** [map ~jobs thunks] runs [thunks] with at most [jobs] child processes alive
    at once and returns one result per thunk, in the order of [thunks].

    [on_start i] runs in the caller as job [i] begins. [on_result i result]
    runs in the caller once for each job, in increasing [i], as soon as every
    earlier job has finished, so a caller that prints each result prints them in
    job order while the later jobs are still running.

    With [jobs <= 1], or with one job, the jobs run one after another in the
    calling process, and an exception is reported as [Raised] the same way.

    When the caller gets SIGINT or SIGTERM while children run, it kills them,
    removes their result files, and then ends with that signal. *)
