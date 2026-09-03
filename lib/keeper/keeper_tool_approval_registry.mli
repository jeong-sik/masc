(** Holds a keeper turn at a tool call until an operator answers, or the wait
    runs out.

    {!Agent_core.Hooks.tool_approval_callback} is synchronous and must return a
    closed decision: its contract says a caller needing a timeout enforces it
    itself and reports [Timed_out]. So the wait lives here — the turn's fiber
    blocks in [await] while the fiber serving the operator's decision calls
    [settle].

    {2 What this is not}

    Not a queue and not a scheduler. One tool call, one waiter, one answer.
    A call whose waiter is gone is not held for later: [settle] says the answer
    arrived too late rather than storing it, because an approval that outlives
    the turn it was asked about would authorize a call nobody is making. The
    answer itself is not lost, though: the HTTP handler passes it to
    {!Keeper_late_approval}, which can settle only the identical call made
    again — never a call nobody is making. *)

type t

val create : unit -> t

val shared : unit -> t
(** The registry the running server uses.

    One instance rather than an installed slot: the turn fiber that waits and
    the HTTP handler that answers have to reach the same waits, and a slot
    would add a state where one of them reaches nothing. [create] stays for
    tests, which want an empty one per case. *)

(** What an operator said about one tool call. *)
type decision =
  | Approve
  | Deny

val decision_to_string : decision -> string
val decision_of_string : string -> decision option

(** How the wait ended. *)
type outcome =
  | Answered of decision
  | Timed_out
  | Displaced
      (** A second wait opened on the same tool call id and this one was
          dropped. Reported rather than merged: two waits mean the id is not
          identifying one call, and answering both from one decision would
          approve a call the operator never saw. *)

val await :
  t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_name:string ->
  tool_call_id:string ->
  tool_name:string ->
  args:string ->
  question:string ->
  because:string ->
  timeout_sec:float ->
  outcome
(** Register a wait and block until it settles.

    [timeout_sec] is required. A wait with no bound would park the keeper's
    turn for the life of the process if nobody is watching, and how long an
    operator gets to answer is a policy this module cannot know.

    [tool_name], [args], [question] and [because] describe the ask for
    {!pending}: a listing of bare call ids gave an operator nothing to decide
    on, so a wait only visible to the stream that opened it timed out
    unanswered whenever that stream's watcher was gone (masc#30034). They
    identify nothing — the wait's identity stays (keeper, call id). [because]
    is the policy's reason for asking rather than running; an operator reading
    the pending list has no other view of the policy table.

    The entry is removed before returning on every path, so a caller that
    raises through [await] — cancellation included — does not leave a waiter
    behind. *)

val settle :
  t -> keeper_name:string -> tool_call_id:string -> decision -> bool
(** Answer a wait. Returns whether one was actually waiting: [false] means it
    had already timed out, been answered, or never opened. Callers report that
    rather than treating it as success, so an operator is not told a call was
    approved when nothing was listening. *)

(** One wait, for the operator-facing listing. The description fields say
    what is being asked; identity stays (keeper, call id). [asked_at] is the
    registry clock's reading when the wait opened, so a consumer derives age
    against the same clock family. *)
type pending =
  { keeper_name : string
  ; tool_call_id : string
  ; tool_name : string
  ; args : string
  ; question : string
  ; because : string
  ; asked_at : float
  ; timeout_sec : float
  }

val pending : t -> pending list
(** Every wait currently open, oldest first. *)
