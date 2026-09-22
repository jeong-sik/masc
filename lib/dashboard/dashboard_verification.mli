(** Dashboard projection for immutable verification submissions.

    Requests contain the submit-time completion contract and evidence envelope.
    Task status is the sole source of the pending obligation and terminal
    outcome; this projection therefore exposes no request-level status, verdict,
    or authority identity. *)

(** Which question the caller asks of the request store. The store has no
    removal path, so reading it as one list answers "what was ever submitted"
    rather than "what is waiting". *)
type requested_view =
  | Ask_awaiting
  | Ask_all

val requested_view_to_string : requested_view -> string

val requested_view_of_string : string -> (requested_view, string) result
(** An unrecognised name is refused rather than defaulted to either view. *)

(** What the backlog is waiting on, read by the caller. [Backlog_unreadable]
    is distinct from an empty list: only one of them means there is no work. *)
(** One task the backlog is waiting on: the request it names and which
    terminal state its verdict authorises. A cancellation waits on the same
    queue as a completion and only an operator's verdict clears it, so the
    row has to say which one it is. *)
type awaiting_task =
  { request_id : string
  ; intent : Masc_domain.verification_intent
  }

type awaiting_join =
  | Backlog_read of { live : awaiting_task list }
  | Backlog_recovered of
      { live : awaiting_task list
      ; detail : string
      }
      (** The primary backlog did not read and a [.last-good] snapshot did.
          The queue is as old as that snapshot, so a task that submitted after
          it is absent. Reported rather than folded into [Backlog_read], which
          made a stale queue look current. *)
  | Backlog_unreadable of string

(** The view with everything needed to answer it. The queue cannot be resolved
    without the backlog, so the queue view carries the join. *)
type queue_view =
  | Awaiting_operator of awaiting_join
  | All_requests

val awaiting_tasks : Masc_domain.backlog -> awaiting_task list
(** The request id and intent each [AwaitingVerification] task names. A task
    re-submitted N times leaves N records in the store and waits on exactly one
    of them, so the queue joins on this id rather than matching on status. *)

val requests_json :
  base_path:string ->
  ?task_id:string ->
  ?limit:int ->
  ?offset:int ->
  ?view:queue_view ->
  unit ->
  Yojson.Safe.t
(** Defaults to [All_requests] at [offset] 0, which is what callers predating
    the view parameter asked for. In the awaiting view each row carries
    [intent] (["complete"] or ["cancel"]) read from the task it waits for;
    the history view has no backlog join and carries [null] there. Carries [total], [offset], [returned] and
    [truncated] so a reader can page without deriving the boundary.

    Paging is by offset into a newest-first list, so a submission that lands
    between two page reads shifts every later row down by one and the reader
    steps over exactly as many rows as arrived. Acceptable for someone
    pressing a key through history; not acceptable for a consumer that walks
    every page to build a record from it. Such a consumer needs a cursor, not
    this. *)

(** Summary of immutable submissions: update time and total count only. *)
val summary_json : base_path:string -> unit -> Yojson.Safe.t

val proof_compose :
  base_path:string ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t * Yojson.Safe.t
