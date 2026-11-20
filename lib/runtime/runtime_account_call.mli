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

    It is called from an Eio fiber. A call made inside a call of the same
    account waits for itself and never runs; {!one_call_of} gives [busy]
    there. *)
val call_in_turn_of : Authz_types.Provider_account_id.t -> (t -> 'a) -> 'a
