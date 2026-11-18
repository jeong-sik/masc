(* HIGH-RISK-UNREVIEWED: the directory made here is the home an official
   client keeps an account in. A home another user of the machine reaches, or
   one under another spelling than the layout's, is another account. *)

(** The directory of an account home, made as
    {!Runtime_account_home_layout} spells it. A login makes the home its
    client signs in to ({!Runtime_setup_login_client}), and the registration
    of an API key makes the home its client runs in
    ({!Runtime_key_account_files}).

    The functions call the system directly and raise [Unix.Unix_error]. A
    caller in a fiber runs them on a system thread. *)

(** Whether [path] is a directory of this user, read without following a link.
    With [private_:true] no other user reaches it (mode [0700] or narrower).
    With [private_:false] no other user writes it. *)
val directory : private_:bool -> string -> (unit, string) result

(** Syncs the directory [path], so a name made or removed in it stays so after
    a crash. *)
val sync_folder : string -> unit

(** Makes the home of the new account [account_id] of [client] under
    [runtime_root] and returns its path, the spelling of
    {!Runtime_account_home_layout.home}. The runtime root is there, a
    directory of this user that no other user writes. Each directory under it
    on the way is made [0700] when it is not there, is a private directory of
    this user when it is, and the directory it is in is synced. *)
val make
  :  runtime_root:string
  -> account_id:string
  -> client:Runtime_account_home_layout.client
  -> (string, string) result
