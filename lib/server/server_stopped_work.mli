(* HIGH-RISK-UNREVIEWED: what this ends removes the keys of people from the
   server. *)

(** What a stopped server left, ended at the start of the next one.

    [start] forks one fiber on [sw] that runs, one after the other:

    - the removals of key accounts ({!Server_key_account_purge.resume}),
    - the removal of the files a key replacement left
      ({!Server_key_account_replacement.remove_left_keys}),
    - the deletions of conversations
      ({!Server_keeper_conversation_purge.resume}).

    The access of the server is published before, since each takes the call
    of its account as a request of its owner does. The server serves while
    the fiber runs. What each does with an account it cannot work on, and
    with an exception, is said at each. *)
val start
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> zone:Authz_zone.t
  -> base_path:string
  -> unit
