(** One call of an account at a time.

    A call starts the official client on the home of an account, and no two
    clients refresh the credential of one home at once. So a verification, a
    turn of a Keeper and a change of the key of one account take turns
    (issue #50018). An account has one owner, so its id is the key. It holds
    within this process. *)

(** The call of an account that is running. Only {!one_call_of} and
    {!call_in_turn_of} make one, and they hand it to the work they run. The
    type keeps a caller from making one. It does not keep the work from
    handing the value on: a value that outlives its call, given back as the
    result or kept by a fiber the work started, names a call that ended. *)
type t

(** The account the call is of. *)
val account : t -> Authz_types.Provider_account_id.t

(** Outcome of a non-blocking account-slot acquisition. *)
type 'a acquire_result =
  | Acquired of 'a
  | Account_busy of Authz_types.Provider_account_id.t

(** Non-blocking acquisition of the account's call slot. Runs [f] and returns
    [Acquired v] when no other call of the account is running; returns
    [Account_busy account_id] immediately without blocking when the slot is
    held by another fiber so failover can rotate to the next candidate. *)
val try_acquire
  :  Authz_types.Provider_account_id.t
  -> (t -> 'a)
  -> 'a acquire_result

(** Runs [f] when no other call of the account runs, and gives [busy]
    otherwise. It does not wait, so it never runs ahead of a call that
    waits its turn. [f] gets the call it runs in. *)
val one_call_of
  :  Authz_types.Provider_account_id.t
  -> busy:'e
  -> (t -> ('a, 'e) result)
  -> ('a, 'e) result

(** Runs [f] when the calls of the account that came before it have ended.
    The calls that wait run in the order they came. [f] gets the call it
    runs in.

    The wait has no time limit of its own. It ends when the fiber that waits
    is cancelled. [f] does not run in a cancelled fiber, whether the fiber
    was cancelled before it came, while it waited or after the call was
    handed to it.

    It is called from an Eio fiber. Outside one it raises
    [Effect.Unhandled] and leaves the account as it was. A call made inside
    a call of the same account waits for itself and never runs;
    {!one_call_of} gives [busy] there. *)
val call_in_turn_of : Authz_types.Provider_account_id.t -> (t -> 'a) -> 'a

(** Bounded FIFO acquisition of the account's call slot.

    Behaves like {!call_in_turn_of} (preserving strict FIFO mutex ordering
    among waiters and never jumping ahead of a queued fiber), but bounds ONLY
    the slot-admission wait by [timeout_s] using [clock]. Once the slot is
    acquired, [f] runs outside the wait timeout so a healthy long turn is
    never cancelled by the admission budget.

    Returns [Account_busy account_id] if the wait budget expires before the
    slot becomes available (or when [timeout_s] is non-positive or non-finite,
    in which case it delegates to {!try_acquire}). On timeout or outer fiber
    cancellation, [entry.users] is decremented and any lock acquired right at
    the handover boundary is released cleanly before returning or re-raising. *)
val call_in_turn_of_with_timeout
  :  clock:_ Eio.Time.clock
  -> timeout_s:float
  -> Authz_types.Provider_account_id.t
  -> (t -> 'a)
  -> 'a acquire_result
