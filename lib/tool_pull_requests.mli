(** [keeper_pull_requests_list]: the open pull requests the server last read,
    answered from {!Repository_pulls.current} (RFC
    keeper-world-state-shows-open-work §4.7).

    GitHub is not called, so a call costs no request and shows at most the
    60 s old reading the server holds. Every Keeper reads every registered
    repository; the checkout of the caller does not narrow the answer.

    The rows are a leaner projection of the snapshot than the HTTP route's:
    they leave out each review's commit id and the repository slug (the row
    sits under its repository), and report [on_head] for each review instead. *)

(** Which placements (see {!Repository_pulls_placement}) the rows may have. *)
type selection =
  | Needs_only  (** The placements that need work ([Needs _]): the default. *)
  | Every_placement
  | Only of Repository_pulls_placement.placement

type request =
  { repository : string option
        (** The name of one repository as the answer shows it: its [owner/repo]
            slug, or its repository id when it has none. [None] is every
            repository. *)
  ; selection : selection
  ; mine : bool
        (** Only pull requests whose newest single-parent commit was written by
            the calling Keeper. *)
  ; limit : int  (** Most rows per repository, in [\[1, max_limit\]]. *)
  }

val default_limit : int
val max_limit : int

val selection_names : string list
(** The values the ["placement"] argument accepts: ["needs"], ["all"], then
    every placement by {!Repository_pulls_placement.to_string}. *)

val request_of_args : Yojson.Safe.t -> (request, Tool_args.field_error list) result
(** Reads ["repository"], ["placement"], ["mine"] and ["limit"]. An unknown
    ["placement"] value or a ["limit"] outside the range is an error. *)

type refusal =
  | Unknown_repository of
      { requested : string
      ; registered : string list
      }
  | Nothing_read of Yojson.Safe.t
      (** No repository asked for holds a reading: the reader is not ready, the
          repository list could not be read, or every repository failed. The
          payload is the answer that would have been sent, with each state. *)
  | Keepers_unread
      (** [mine] was asked while the snapshot holds no Keeper list, so no pull
          request can be called the caller's. *)

val answer
  :  now:float
  -> caller:string
  -> request
  -> Repository_pulls.snapshot
  -> (Yojson.Safe.t, refusal) result
(** The reader, the stored error of the repository list, whether the Keeper
    list is read, and one entry per repository: its state, age, count of open
    pull requests, count per placement, and the rows that [request] selects,
    ordered by placement, then the caller's own first, then head review (not
    reviewed, history incomplete, reviewed, unknown), then number. *)

val handle
  :  tool_name:string
  -> start_time:Tool_timing.started
  -> caller:string
  -> Yojson.Safe.t
  -> Tool_result.result
